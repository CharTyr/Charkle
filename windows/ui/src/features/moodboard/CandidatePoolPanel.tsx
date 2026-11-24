import React, { useEffect, useMemo, useState } from 'react';
import {
  AlertTriangle,
  ArrowDownCircle,
  ArrowLeftRight,
  ArrowUp,
  Box,
  CheckCircle2,
  ChevronRight,
  CircleDashed,
  Clipboard,
  FileText,
  Film,
  Globe,
  Image as ImageIcon,
  Images,
  Layers,
  Music,
  Palette,
  Plus,
  PlusSquare,
  Puzzle,
  RefreshCw,
  Search,
  Share,
  Sparkles,
  X,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import { isLightHex, useResolvedIsDark } from '../../design-system';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';
import type {
  AssetRecord,
  BoardImageFormat,
  MoodboardExportOptions,
  ScoredAsset,
} from '../../types/domain';
import { beginPointerDrag, wasRecentPointerDrag } from '../dnd/PointerDragContext';
import { sanitizeExportFileName } from './editorial';

export const CANDIDATE_DRAG_MIME = 'application/x-charkle-candidate-asset-id';

function withCacheBust(url: string, updatedAt: number | string | undefined): string {
  if (!url || url.startsWith('data:') || url.startsWith('blob:') || updatedAt === undefined) {
    return url;
  }
  const sep = url.includes('?') ? '&' : '?';
  return `${url}${sep}v=${encodeURIComponent(String(updatedAt))}`;
}

function renderTileFallbackIcon(kind: AssetRecord['mediaKind'], size = 16) {
  switch (kind) {
    case 'video':
    case 'animatedImage':
      return <Film size={size} strokeWidth={1.6} />;
    case 'audio':
      return <Music size={size} strokeWidth={1.6} />;
    case 'document':
      return <FileText size={size} strokeWidth={1.6} />;
    case 'webBookmark':
      return <Globe size={size} strokeWidth={1.6} />;
    case 'model3D':
      return <Box size={size} strokeWidth={1.6} />;
    default:
      return <ImageIcon size={size} strokeWidth={1.6} />;
  }
}

const CandidateTileMedia: React.FC<{ asset: AssetRecord; compact?: boolean }> = ({
  asset,
  compact = false,
}) => {
  const transport = getTransport();
  const isSwatch = asset.fileName.toLowerCase().endsWith('.swatch');
  const thumbUrl = isSwatch
    ? ''
    : withCacheBust(transport.thumbnailUrl(asset.id, 'grid520'), asset.updatedAt);
  const [imgFailed, setImgFailed] = useState(false);

  useEffect(() => {
    setImgFailed(false);
  }, [thumbUrl]);

  const primaryHex = asset.dominantColors?.[0]?.hex?.trim() || null;
  const secondaryHex = asset.dominantColors?.[1]?.hex?.trim() || null;
  const swatchHex = (primaryHex || '#64748B').toUpperCase();
  const swatchLight = isLightHex(swatchHex);
  const displayTitle = asset.title || asset.fileName || '未命名素材';

  const backdropStyle: React.CSSProperties = isSwatch
    ? { backgroundColor: swatchHex }
    : primaryHex && secondaryHex
      ? { backgroundImage: `linear-gradient(135deg, ${primaryHex}3D 0%, ${secondaryHex}2B 100%)` }
      : primaryHex
        ? { backgroundColor: `${primaryHex}30` }
        : {};

  return (
    <div style={backdropStyle} className="relative w-full h-full bg-[var(--bg-elevated)]">
      {isSwatch ? (
        <div className="w-full h-full flex items-center justify-center px-1">
          <span
            style={{ color: swatchLight ? 'rgba(0,0,0,0.78)' : 'rgba(255,255,255,0.92)' }}
            className={compact ? 'text-[9.5px] font-semibold charkle-mono' : 'text-[10.5px] font-semibold charkle-mono'}
          >
            {swatchHex}
          </span>
        </div>
      ) : !imgFailed && thumbUrl ? (
        <img
          src={thumbUrl}
          alt={displayTitle}
          loading="lazy"
          draggable={false}
          onError={() => setImgFailed(true)}
          className="w-full h-full object-cover charkle-media-zoom"
        />
      ) : (
        <div
          className={[
            'w-full h-full flex items-center justify-center px-1.5 text-[var(--text-secondary)]',
            compact ? 'pb-2.5' : 'pb-3',
          ].join(' ')}
        >
          {renderTileFallbackIcon(asset.mediaKind, compact ? 15 : 18)}
        </div>
      )}
    </div>
  );
};

export interface CandidatePoolPanelProps {
  onAddAsset?: (asset: AssetRecord) => void;
  onExportFigmaBundle?: () => void;
  onCopyBoardImage?: () => void;
  onSaveBoardImage?: (format: BoardImageFormat) => void;
  onCopyHex?: (hex: string) => void;
  onSearchByColorHex?: (hex: string) => void;
  exporting?: boolean;
}

const SectionCard: React.FC<{
  title: string;
  icon: React.ReactNode;
  trailing?: React.ReactNode;
  children: React.ReactNode;
}> = ({ title, icon, trailing, children }) => (
  <section className="rounded-[var(--radius-card-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-3 flex flex-col gap-2.5">
    <div className="flex items-center justify-between gap-2">
      <div className="flex items-center gap-1.5 min-w-0">
        <span className="shrink-0 text-[var(--text-secondary)]">{icon}</span>
        <h3 className="text-[11.5px] font-semibold text-[var(--text-primary)] truncate">
          {title}
        </h3>
      </div>
      {trailing && <div className="shrink-0">{trailing}</div>}
    </div>
    {children}
  </section>
);

/**
 * Moodboard Inspector Right Rail matching macOS `InspectorView.moodboardRightRail` 1:1:
 * 1. Board Identity + Active Board & Offline Pin controls
 * 2. In-Canvas AI Curator Assistant (with 3 quick chips & Undo support)
 * 3. Candidate Swap Pool (click-to-swap & drag-to-canvas)
 * 4. Harmonious Board Palette + Re-extract
 * 5. Quick Add from Library Search
 * 6. Export & Delivery (.charkleboard / Copy 2x / Save PNG / Save JPG)
 */
export const CandidatePoolPanel: React.FC<CandidatePoolPanelProps> = ({
  onAddAsset,
  onExportFigmaBundle,
  onCopyBoardImage,
  onSaveBoardImage,
  onCopyHex,
  onSearchByColorHex,
  exporting: externalExporting = false,
}) => {
  const activeMoodboardId = useCoordinatorStore((s) => s.activeMoodboardId);
  const setActiveMoodboardId = useCoordinatorStore((s) => s.setActiveMoodboardId);
  const openSettings = useCoordinatorStore((s) => s.openSettings);
  const setDestination = useCoordinatorStore((s) => s.setDestination);
  const setVisualFilterBarOpen = useCoordinatorStore((s) => s.setVisualFilterBarOpen);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const allLibraryAssets = useLibraryStore((s) => s.allAssets);
  const filteredLibraryAssets = useLibraryStore((s) => s.assets);
  const libraryAssets = allLibraryAssets.length > 0 ? allLibraryAssets : filteredLibraryAssets;
  const setCriteria = useLibraryStore((s) => s.setCriteria);

  const activeBoard = useMoodboardStore((s) => s.activeBoard);
  const selectedNodeIds = useMoodboardStore((s) => s.selectedNodeIds);
  const swappingNodeId = useMoodboardStore((s) => s.swappingNodeId);
  const setSwappingNodeId = useMoodboardStore((s) => s.setSwappingNodeId);
  const candidatePool = useMoodboardStore((s) => s.candidatePool);
  const isRefiningActiveBoard = useMoodboardStore((s) => s.isRefiningActiveBoard);
  const activeBoardAgentTrace = useMoodboardStore((s) => s.activeBoardAgentTrace);
  const activeBoardLastSummary = useMoodboardStore((s) => s.activeBoardLastSummary);
  const historyPast = useMoodboardStore((s) => s.historyPast);
  const undo = useMoodboardStore((s) => s.undo);
  const mutateActiveBoard = useMoodboardStore((s) => s.mutateActiveBoard);
  const setBoardPinnedOffline = useMoodboardStore((s) => s.setBoardPinnedOffline);
  const swapNodeAsset = useMoodboardStore((s) => s.swapNodeAsset);
  const syncBoardPalette = useMoodboardStore((s) => s.syncBoardPalette);
  const addAssetNodeAt = useMoodboardStore((s) => s.addAssetNodeAt);
  const refineActiveBoard = useMoodboardStore((s) => s.refineActiveBoard);

  const isDark = useResolvedIsDark();
  const transport = getTransport();

  const [titleDraft, setTitleDraft] = useState(activeBoard?.title ?? '');
  const [subtitleDraft, setSubtitleDraft] = useState(activeBoard?.subtitle ?? '');
  const [refineText, setRefineText] = useState('');
  const [showTrace, setShowTrace] = useState(false);
  const [quickAddQuery, setQuickAddQuery] = useState('');
  const [localExporting, setLocalExporting] = useState(false);

  const isExporting = externalExporting || localExporting;

  useEffect(() => {
    setTitleDraft(activeBoard?.title ?? '');
    setSubtitleDraft(activeBoard?.subtitle ?? '');
  }, [activeBoard?.id, activeBoard?.title, activeBoard?.subtitle]);

  useEffect(() => {
    setRefineText('');
    setShowTrace(false);
  }, [activeBoard?.id]);

  const assetsById = useMemo(
    () => new Map<string, AssetRecord>(libraryAssets.map((a) => [a.id, a])),
    [libraryAssets],
  );

  const safeNodes = useMemo(
    () => (Array.isArray(activeBoard?.nodes) ? activeBoard.nodes : []),
    [activeBoard?.nodes],
  );

  const onBoardAssetIds = useMemo(() => {
    const set = new Set<string>();
    for (const n of safeNodes) {
      if ('assetRef' in n.kind && n.kind.assetRef.assetID) {
        set.add(n.kind.assetRef.assetID);
      }
    }
    return set;
  }, [safeNodes]);

  const selectedAssetNodeId = useMemo(() => {
    if (selectedNodeIds.length !== 1) return null;
    const node = safeNodes.find((n) => n.id === selectedNodeIds[0]);
    return node && 'assetRef' in node.kind ? node.id : null;
  }, [safeNodes, selectedNodeIds]);

  const effectiveSwapNodeId = swappingNodeId ?? selectedAssetNodeId;

  const displayedCandidates = useMemo<ScoredAsset[]>(() => {
    if (!activeBoard) return [];
    if (Array.isArray(candidatePool) && candidatePool.length > 0) {
      const fresh = candidatePool
        .filter((c) => {
          if (!c?.asset || onBoardAssetIds.has(c.asset.id)) return false;
          if (assetsById.size > 0) {
            const live = assetsById.get(c.asset.id);
            if (!live || live.isTrashed) return false;
          }
          return !c.asset.isTrashed;
        })
        .map((c) => {
          const live = assetsById.get(c.asset.id);
          return live ? { ...c, asset: live } : c;
        });
      if (fresh.length > 0) return fresh.slice(0, 24);
    }

    const candIds = Array.isArray(activeBoard.candidateAssetIDs)
      ? activeBoard.candidateAssetIDs
      : [];
    const fromIds = candIds
      .filter((id) => !onBoardAssetIds.has(id))
      .map((id) => assetsById.get(id))
      .filter((a): a is AssetRecord => Boolean(a && !a.isTrashed))
      .map((asset) => ({ asset, score: 0.78, matchReasons: ['策展备选'] }));

    if (fromIds.length > 0) return fromIds.slice(0, 24);

    return libraryAssets
      .filter((a) => !a.isTrashed && !onBoardAssetIds.has(a.id))
      .slice(0, 24)
      .map((asset) => ({ asset, score: 0.65, matchReasons: ['素材库推荐'] }));
  }, [activeBoard, candidatePool, libraryAssets, assetsById, onBoardAssetIds]);

  const quickAddResults = useMemo(() => {
    const q = quickAddQuery.trim().toLowerCase();
    return libraryAssets
      .filter((a) => {
        if (a.isTrashed || onBoardAssetIds.has(a.id)) return false;
        if (!q) return true;
        if (a.title.toLowerCase().includes(q)) return true;
        if (a.fileName.toLowerCase().includes(q)) return true;
        if (a.sourceDomain?.toLowerCase().includes(q)) return true;
        if (a.tags.some((t) => t.toLowerCase().includes(q))) return true;
        return false;
      })
      .slice(0, 9);
  }, [libraryAssets, onBoardAssetIds, quickAddQuery]);

  if (!activeBoard) return null;

  const extractedPalette = Array.isArray(activeBoard.extractedPalette)
    ? activeBoard.extractedPalette
    : [];
  const isActiveBoard = activeMoodboardId === activeBoard.id;

  const commitIdentity = () => {
    const nextTitle = titleDraft.trim() || activeBoard.title;
    const nextSubtitle = subtitleDraft.trim();
    if (nextTitle !== activeBoard.title || nextSubtitle !== activeBoard.subtitle) {
      mutateActiveBoard(
        (doc) => ({ ...doc, title: nextTitle, subtitle: nextSubtitle }),
        { immediateSave: true },
      );
    }
  };

  const runRefinement = async (instruction: string) => {
    const trimmed = instruction.trim();
    if (!trimmed || isRefiningActiveBoard) return;
    setRefineText('');
    try {
      await refineActiveBoard(trimmed, assetsById);
    } catch {
      // handled with toast in store
    }
  };

  const handleCopyHex = (hex: string) => {
    const upper = hex.toUpperCase();
    if (onCopyHex) {
      onCopyHex(upper);
      return;
    }
    void navigator.clipboard?.writeText(upper).catch(() => {});
    pushToast({ message: `已复制色值 ${upper}`, tone: 'info', durationMs: 2000 });
  };

  const handleSearchColor = (hex: string) => {
    const upper = hex.toUpperCase();
    if (onSearchByColorHex) {
      onSearchByColorHex(upper);
      return;
    }
    const boardId = activeBoard.id;
    setDestination({ type: 'allItems' });
    setVisualFilterBarOpen(true);
    void setCriteria({ selectedColorHex: upper }, { type: 'allItems' });
    pushToast({
      message: `已按色值 ${upper} 筛选素材库`,
      tone: 'info',
      actionLabel: '返回情绪板',
      durationMs: 5500,
      onAction: () => setDestination({ type: 'moodboard', id: boardId }),
    });
  };

  const handleAddAssetToCanvas = (asset: AssetRecord) => {
    if (onAddAsset) {
      onAddAsset(asset);
    } else {
      addAssetNodeAt(asset.id, undefined, asset, assetsById);
    }
  };

  const hasExportableContent =
    safeNodes.length > 0 ||
    (Array.isArray(activeBoard.inkStrokes) && activeBoard.inkStrokes.length > 0);

  const fallbackOptions = (format: BoardImageFormat): MoodboardExportOptions => ({
    scale: 2,
    format,
    includeAnnotations: true,
    includePaletteStrip: true,
    darkAppearance: isDark,
    containerWidth: 1120,
  });

  const triggerExportFigma = async () => {
    if (isExporting) return;
    if (onExportFigmaBundle) {
      onExportFigmaBundle();
      return;
    }
    if (!hasExportableContent) {
      pushToast({ message: '当前画布暂无可导出的素材或批注', tone: 'info', durationMs: 2400 });
      return;
    }
    setLocalExporting(true);
    try {
      const stem = sanitizeExportFileName(activeBoard.title);
      const dest = await transport.saveFileDialog(`${stem}.charkleboard`, [
        { name: 'Charkle Figma Bridge', extensions: ['charkleboard'] },
      ]);
      if (!dest) return;
      const report = await transport.exportBoardFigmaBridge(
        activeBoard,
        fallbackOptions('png'),
        dest,
      );
      pushToast({
        message: `已导出 .charkleboard（${report.objectCount} 个图层）`,
        tone: 'success',
        durationMs: 4200,
      });
    } catch (err) {
      pushToast({
        message: `导出失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setLocalExporting(false);
    }
  };

  const triggerCopyImage = async () => {
    if (isExporting) return;
    if (onCopyBoardImage) {
      onCopyBoardImage();
      return;
    }
    if (!hasExportableContent) {
      pushToast({ message: '当前画布暂无可导出的素材或批注', tone: 'info', durationMs: 2400 });
      return;
    }
    setLocalExporting(true);
    try {
      await transport.copyBoardImageToClipboard(activeBoard, fallbackOptions('png'));
      pushToast({
        message: '已复制高清情绪板到剪贴板，可直接 Ctrl+V 粘贴',
        tone: 'success',
      });
    } catch (err) {
      pushToast({
        message: `复制失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setLocalExporting(false);
    }
  };

  const triggerSaveImage = async (format: BoardImageFormat) => {
    if (isExporting) return;
    if (onSaveBoardImage) {
      onSaveBoardImage(format);
      return;
    }
    if (!hasExportableContent) {
      pushToast({ message: '当前画布暂无可导出的素材或批注', tone: 'info', durationMs: 2400 });
      return;
    }
    setLocalExporting(true);
    try {
      const ext = format === 'png' ? 'png' : 'jpg';
      const stem = sanitizeExportFileName(activeBoard.title);
      const dest = await transport.saveFileDialog(`${stem}.${ext}`, [
        { name: format.toUpperCase(), extensions: [ext] },
      ]);
      if (!dest) return;
      const bytes = await transport.exportBoardImageFile(activeBoard, fallbackOptions(format), dest);
      pushToast({
        message: `已保存 2× ${format.toUpperCase()}（${Math.round(bytes / 1024)} KB）`,
        tone: 'success',
      });
    } catch (err) {
      pushToast({
        message: `保存失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setLocalExporting(false);
    }
  };

  const latestStep =
    activeBoardAgentTrace.length > 0
      ? activeBoardAgentTrace[activeBoardAgentTrace.length - 1]
      : null;

  return (
    <aside
      data-testid="candidate-pool-panel"
      aria-label="情绪板检查器"
      className="w-[300px] shrink-0 h-full bg-[var(--bg-inspector)] border-l border-[var(--border-hairline)] flex flex-col overflow-hidden select-none"
    >
      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-3 flex flex-col gap-2.5">
        {/* Card 1: Board Identity & Status Controls */}
        <section className="rounded-[var(--radius-card-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-3 flex flex-col gap-2">
          <input
            type="text"
            value={titleDraft}
            aria-label="情绪板名称"
            placeholder="情绪板名称"
            onChange={(e) => setTitleDraft(e.target.value)}
            onBlur={commitIdentity}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.nativeEvent.isComposing) {
                e.currentTarget.blur();
              }
            }}
            className="w-full bg-transparent text-[14.5px] font-semibold text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
          />
          <input
            type="text"
            value={subtitleDraft}
            aria-label="氛围备注"
            placeholder="补充创作 Brief 或氛围备注…"
            onChange={(e) => setSubtitleDraft(e.target.value)}
            onBlur={commitIdentity}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.nativeEvent.isComposing) {
                e.currentTarget.blur();
              }
            }}
            className="w-full bg-transparent text-[11.5px] text-[var(--text-secondary)] placeholder:text-[var(--text-tertiary)] outline-none"
          />

          <div className="h-px bg-[var(--border-hairline)] my-0.5" />

          <div className="flex items-center gap-1.5 flex-wrap">
            <button
              type="button"
              onClick={() => {
                setActiveMoodboardId(activeBoard.id);
                pushToast({ message: '已设为当前活跃情绪板', tone: 'success', durationMs: 2200 });
              }}
              className="charkle-pressable h-6.5 px-2.5 rounded-full bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)] inline-flex items-center gap-1.5 text-[10.5px] font-medium text-[var(--text-primary)] cursor-pointer"
            >
              <span
                className={[
                  'h-1.5 w-1.5 rounded-full',
                  isActiveBoard ? 'bg-[var(--success)]' : 'bg-[var(--text-tertiary)]/50',
                ].join(' ')}
              />
              <span>{isActiveBoard ? '当前活跃板' : '设为活跃板'}</span>
            </button>

            <button
              type="button"
              onClick={() => void setBoardPinnedOffline(activeBoard.id, !activeBoard.pinnedOffline)}
              title={
                activeBoard.pinnedOffline
                  ? '整板素材已始终保留在本机，离线可用'
                  : '始终将此情绪板引用的素材保留在本机'
              }
              className={[
                'charkle-pressable h-6.5 px-2.5 rounded-full border inline-flex items-center gap-1 text-[10.5px] font-medium cursor-pointer',
                activeBoard.pinnedOffline
                  ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)]'
                  : 'bg-[var(--bg-inspector-field)] border-[var(--border-hairline)] hover:border-[var(--border-strong)] text-[var(--text-primary)]',
              ].join(' ')}
            >
              <ArrowDownCircle size={11.5} />
              <span>{activeBoard.pinnedOffline ? '已保留本地' : '始终保留本地'}</span>
            </button>
          </div>
        </section>

        {/* Card 2: In-Canvas AI Curator Assistant */}
        <SectionCard
          title="AI 策展助手"
          icon={<Sparkles size={13} className="text-[var(--accent)]" />}
          trailing={
            historyPast.length > 0 && !isRefiningActiveBoard ? (
              <button
                type="button"
                onClick={() => {
                  undo();
                  pushToast({ message: '已撤销上一步画布调整', tone: 'info', durationMs: 2200 });
                }}
                title="撤销上一步 (Ctrl+Z)"
                className="text-[10.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
              >
                撤销
              </button>
            ) : null
          }
        >
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void runRefinement(refineText);
            }}
            className="flex items-center gap-1.5"
          >
            <input
              type="text"
              value={refineText}
              disabled={isRefiningActiveBoard}
              onChange={(e) => setRefineText(e.target.value)}
              placeholder="输入指令微调当前情绪板…"
              className="flex-1 min-w-0 h-7 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[11.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none focus:border-[var(--accent)] disabled:opacity-60"
            />
            <button
              type="submit"
              disabled={!refineText.trim() || isRefiningActiveBoard}
              aria-label="执行 AI 策展微调"
              title="执行 AI 策展微调"
              className="charkle-pressable h-7 w-7 shrink-0 rounded-[7px] bg-[var(--accent)] text-white inline-flex items-center justify-center cursor-pointer disabled:opacity-45 disabled:cursor-not-allowed"
            >
              {isRefiningActiveBoard ? (
                <CircleDashed size={12.5} className="animate-spin" />
              ) : (
                <ArrowUp size={12.5} />
              )}
            </button>
          </form>

          <div className="grid grid-cols-3 gap-1.5">
            {[
              {
                label: '重新分区编排',
                prompt: '按视觉层次重新划分为清晰分区，突出主视觉并补充简短美术指导批注',
              },
              {
                label: '补充同氛围图',
                prompt: '保留当前核心素材，从素材库补充 4 到 6 张色调与气质一致的高质量参考图',
              },
              {
                label: '精简不协调',
                prompt: '严格审视当前画布，剔除风格、构图或色温不协调的素材，宁缺毋滥',
              },
            ].map((chip) => (
              <button
                key={chip.label}
                type="button"
                disabled={isRefiningActiveBoard}
                onClick={() => void runRefinement(chip.prompt)}
                className="charkle-pressable h-6.5 px-1.5 rounded-[6px] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)] text-[10px] font-medium text-[var(--text-primary)] truncate cursor-pointer disabled:opacity-45"
              >
                {chip.label}
              </button>
            ))}
          </div>

          {isRefiningActiveBoard && latestStep && (
            <div className="flex items-start gap-2 pt-0.5 text-[10.5px]">
              <CircleDashed size={12} className="text-[var(--accent)] animate-spin shrink-0 mt-0.5" />
              <div className="min-w-0">
                <div className="font-semibold text-[var(--text-primary)]">{latestStep.title}</div>
                {latestStep.detail && (
                  <div className="text-[var(--text-secondary)] line-clamp-2">{latestStep.detail}</div>
                )}
              </div>
            </div>
          )}

          {!isRefiningActiveBoard && activeBoardLastSummary && (
            <div className="flex flex-col gap-1.5 pt-0.5">
              <p className="text-[10.5px] text-[var(--text-secondary)] leading-relaxed line-clamp-3">
                {activeBoardLastSummary}
              </p>
              {activeBoardAgentTrace.length > 0 && (
                <div className="flex flex-col gap-1">
                  <button
                    type="button"
                    onClick={() => setShowTrace((v) => !v)}
                    className="w-full min-h-[26px] px-2 py-1 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)]/70 hover:bg-[var(--bg-subtle)] flex items-center justify-between text-[10.5px] font-medium text-[var(--text-secondary)] cursor-pointer"
                  >
                    <span>
                      {showTrace
                        ? '收起策展步骤'
                        : `查看策展步骤（${activeBoardAgentTrace.length} 步）`}
                    </span>
                    <ChevronRight
                      size={11}
                      style={{
                        transform: showTrace ? 'rotate(90deg)' : 'rotate(0deg)',
                        transition: 'transform 160ms var(--ease-out)',
                      }}
                    />
                  </button>
                  {showTrace && (
                    <div className="flex flex-col gap-1 pt-0.5 pl-1">
                      {activeBoardAgentTrace.map((step) => (
                        <div key={step.id} className="flex items-start gap-1.5 text-[10px]">
                          {step.status === 'done' ? (
                            <CheckCircle2 size={11} className="text-[var(--success)] shrink-0 mt-0.5" />
                          ) : step.status === 'warning' ? (
                            <AlertTriangle size={11} className="text-[var(--warning)] shrink-0 mt-0.5" />
                          ) : (
                            <CircleDashed size={11} className="text-[var(--accent)] shrink-0 mt-0.5" />
                          )}
                          <div className="min-w-0">
                            <div className="font-medium text-[var(--text-primary)]">{step.title}</div>
                            {step.detail && (
                              <div className="text-[var(--text-tertiary)]">{step.detail}</div>
                            )}
                          </div>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              )}
            </div>
          )}

          <div className="flex items-center justify-between text-[10px] text-[var(--text-tertiary)]">
            <span>已锁定卡片会自动保留 · 支持 Ctrl+Z 撤销</span>
            <span className="charkle-tabular shrink-0">{onBoardAssetIds.size} 张素材</span>
          </div>
        </SectionCard>

        {/* Card 3: Candidate Swap Pool */}
        <SectionCard
          title={swappingNodeId ? '候选替换池' : '同方向候选池'}
          icon={
            swappingNodeId ? (
              <ArrowLeftRight size={13} className="text-[var(--accent)]" />
            ) : (
              <Images size={13} />
            )
          }
          trailing={
            swappingNodeId ? (
              <button
                type="button"
                onClick={() => setSwappingNodeId(null)}
                className="text-[10.5px] font-medium text-[var(--accent)] hover:underline cursor-pointer"
              >
                取消替换
              </button>
            ) : displayedCandidates.length > 0 ? (
              <span className="text-[10px] text-[var(--text-tertiary)] charkle-tabular">
                点击或拖入 · {displayedCandidates.length} 项
              </span>
            ) : null
          }
        >
          {swappingNodeId && (
            <div className="px-2 py-1.5 rounded-[var(--radius-settings-inner)] bg-[var(--accent-soft)] border border-[var(--accent-ring)] flex items-center gap-1.5 text-[10.5px] font-medium text-[var(--text-primary)]">
              <ArrowLeftRight size={11} className="text-[var(--accent)] shrink-0" />
              <span>点击下方任意候选图即可原地替换选中卡片</span>
            </div>
          )}

          {displayedCandidates.length === 0 ? (
            <p className="text-[11px] text-[var(--text-tertiary)]">
              暂无更多候选图，可从下方直接检索素材库添加。
            </p>
          ) : (
            <div className="grid grid-cols-2 gap-2">
              {displayedCandidates.map((item) => (
                <div
                  key={item.asset.id}
                  onPointerDown={(e) => {
                    if ((e.target as HTMLElement).closest('button')) return;
                    beginPointerDrag(e, {
                      kind: 'candidate',
                      assetId: item.asset.id,
                      title: item.asset.title,
                    });
                  }}
                  onClick={() => {
                    if (wasRecentPointerDrag()) return;
                    if (swappingNodeId) {
                      swapNodeAsset(swappingNodeId, item.asset.id, assetsById);
                    } else {
                      handleAddAssetToCanvas(item.asset);
                      pushToast({ message: `已追加「${item.asset.title}」到情绪板`, tone: 'success', durationMs: 2000 });
                    }
                  }}
                  title={
                    item.matchReasons[0]
                      ? `${item.asset.title} · ${item.matchReasons.join(' / ')}`
                      : item.asset.title
                  }
                  className="group relative w-full h-[84px] rounded-[var(--radius-settings-inner)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] hover:border-[var(--accent)] cursor-grab active:cursor-grabbing transition-colors duration-150"
                >
                  <CandidateTileMedia asset={item.asset} />
                  <div className="pointer-events-none absolute inset-x-0 bottom-0 px-1.5 py-0.5 bg-gradient-to-t from-black/68 via-black/32 to-transparent group-hover:opacity-0 transition-opacity duration-150">
                    <div className="text-[9.5px] font-medium text-white truncate leading-tight">
                      {item.asset.title || item.asset.fileName}
                    </div>
                  </div>
                  <div className="absolute inset-x-1 bottom-1 flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity duration-150">
                    {effectiveSwapNodeId && (
                      <button
                        type="button"
                        onClick={(e) => {
                          e.stopPropagation();
                          if (wasRecentPointerDrag()) return;
                          swapNodeAsset(effectiveSwapNodeId, item.asset.id, assetsById);
                        }}
                        className="charkle-pressable flex-1 h-5.5 px-1.5 rounded-[5px] bg-[var(--accent)] text-white text-[10px] font-medium inline-flex items-center justify-center gap-0.5 cursor-pointer"
                      >
                        <ArrowLeftRight size={9.5} />
                        替换
                      </button>
                    )}
                    <button
                      type="button"
                      aria-label={`添加 ${item.asset.title} 到画布`}
                      onClick={(e) => {
                        e.stopPropagation();
                        if (wasRecentPointerDrag()) return;
                        handleAddAssetToCanvas(item.asset);
                        pushToast({ message: `已追加「${item.asset.title}」到情绪板`, tone: 'success', durationMs: 2000 });
                      }}
                      className="charkle-pressable h-5.5 px-1.5 rounded-[5px] bg-black/72 text-white text-[10px] inline-flex items-center justify-center gap-0.5 cursor-pointer"
                    >
                      <Plus size={10} />
                      添加
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </SectionCard>

        {/* Card 4: Board Harmonious Palette Strip */}
        <SectionCard
          title="全板和谐色板"
          icon={<Palette size={13} />}
          trailing={
            <button
              type="button"
              onClick={() => {
                syncBoardPalette(assetsById);
                pushToast({ message: '已重新提取全板和谐色卡', tone: 'info', durationMs: 2200 });
              }}
              title="重新分析板内素材并更新和谐色板"
              className="inline-flex items-center gap-1 text-[10.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
            >
              <RefreshCw size={10} />
              <span>重新提取</span>
            </button>
          }
        >
          {extractedPalette.length === 0 ? (
            <p className="text-[11px] text-[var(--text-tertiary)]">
              加入素材后将自动提取全板和谐色卡。
            </p>
          ) : (
            <div className="flex items-center gap-1.5">
              {extractedPalette.slice(0, 7).map((swatch) => {
                const hex = swatch.hex.toUpperCase();
                return (
                  <button
                    key={hex}
                    type="button"
                    onClick={() => handleCopyHex(hex)}
                    onContextMenu={(e) => {
                      e.preventDefault();
                      handleSearchColor(hex);
                    }}
                    title={`点击复制 ${hex}，右键以此色筛选素材库`}
                    aria-label={`色卡 ${hex}`}
                    style={{ backgroundColor: hex }}
                    className="charkle-pressable flex-1 h-[30px] rounded-[var(--radius-card-inner)] border border-black/12 dark:border-white/15 cursor-pointer"
                  />
                );
              })}
            </div>
          )}
        </SectionCard>

        {/* Card 5: Quick Add from Library Search */}
        <SectionCard title="从素材库快速拉图" icon={<PlusSquare size={13} />}>
          <div className="relative flex items-center">
            <Search
              size={12}
              className="absolute left-2.5 text-[var(--text-tertiary)] pointer-events-none"
            />
            <input
              type="text"
              value={quickAddQuery}
              onChange={(e) => setQuickAddQuery(e.target.value)}
              placeholder="搜索标题、标签或域名…"
              className="w-full h-7 pl-7 pr-6 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[11.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none focus:border-[var(--accent)]"
            />
            {quickAddQuery && (
              <button
                type="button"
                aria-label="清空搜索"
                onClick={() => setQuickAddQuery('')}
                className="absolute right-1.5 h-4 w-4 rounded-full hover:bg-[var(--bg-subtle)] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] inline-flex items-center justify-center cursor-pointer"
              >
                <X size={10.5} />
              </button>
            )}
          </div>

          {quickAddResults.length > 0 ? (
            <div className="grid grid-cols-3 gap-1.5">
              {quickAddResults.map((asset) => (
                <button
                  key={asset.id}
                  type="button"
                  title={`点击加入或拖入画布：${asset.title}`}
                  onPointerDown={(e) => {
                    beginPointerDrag(e, {
                      kind: 'candidate',
                      assetId: asset.id,
                      title: asset.title,
                    });
                  }}
                  onClick={() => {
                    if (wasRecentPointerDrag()) return;
                    handleAddAssetToCanvas(asset);
                    pushToast({
                      message: `已将「${asset.title}」加入情绪板`,
                      tone: 'success',
                      durationMs: 2000,
                    });
                  }}
                  className="group relative w-full h-[60px] rounded-[var(--radius-card-inner)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] hover:border-[var(--accent)] cursor-grab active:cursor-grabbing text-left"
                >
                  <CandidateTileMedia asset={asset} compact />
                  <div className="pointer-events-none absolute inset-x-0 bottom-0 px-1 py-0.5 bg-gradient-to-t from-black/68 via-black/32 to-transparent">
                    <div className="text-[9px] font-medium text-white truncate leading-tight">
                      {asset.title || asset.fileName}
                    </div>
                  </div>
                </button>
              ))}
            </div>
          ) : quickAddQuery.trim() ? (
            <p className="text-[11px] text-[var(--text-tertiary)]">未找到匹配的素材</p>
          ) : null}
        </SectionCard>

        {/* Card 6: Export & Delivery */}
        <SectionCard
          title="导出与交付"
          icon={<Share size={13} />}
          trailing={
            <button
              type="button"
              onClick={() => openSettings('extensions')}
              title="查看 Figma / FigJam 本地插件安装说明"
              className="inline-flex items-center gap-1 text-[10.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
            >
              <Puzzle size={10.5} />
              <span>插件指南</span>
            </button>
          }
        >
          <div className="flex flex-col gap-1.5">
            <button
              type="button"
              disabled={isExporting}
              onClick={() => void triggerExportFigma()}
              title="导出 .charkleboard 文件，在 Figma / FigJam 中导入为独立可编辑图层"
              className="charkle-pressable w-full px-2.5 py-2 rounded-[var(--radius-settings-inner)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-white text-[11.5px] font-semibold inline-flex items-center gap-1.5 cursor-pointer disabled:opacity-50"
            >
              <Layers size={13} className="shrink-0" />
              <span className="truncate">导出到 Figma / FigJam（可编辑图层）</span>
            </button>

            <button
              type="button"
              disabled={isExporting}
              onClick={() => void triggerCopyImage()}
              className="charkle-pressable w-full px-2.5 py-1.5 rounded-[var(--radius-settings-inner)] bg-[var(--accent-soft)] hover:bg-[var(--accent)]/18 text-[var(--accent)] text-[11.5px] font-medium inline-flex items-center gap-1.5 cursor-pointer disabled:opacity-50"
            >
              <Clipboard size={12.5} className="shrink-0" />
              <span className="truncate">复制 2× 高清图（直接 Ctrl+V 粘贴）</span>
            </button>

            <div className="grid grid-cols-2 gap-1.5">
              <button
                type="button"
                disabled={isExporting}
                onClick={() => void triggerSaveImage('png')}
                className="charkle-pressable h-7.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)] text-[11.5px] font-medium text-[var(--text-primary)] cursor-pointer disabled:opacity-50"
              >
                保存 PNG
              </button>
              <button
                type="button"
                disabled={isExporting}
                onClick={() => void triggerSaveImage('jpeg')}
                className="charkle-pressable h-7.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)] text-[11.5px] font-medium text-[var(--text-primary)] cursor-pointer disabled:opacity-50"
              >
                保存 JPG
              </button>
            </div>
          </div>
        </SectionCard>
      </div>
    </aside>
  );
};
