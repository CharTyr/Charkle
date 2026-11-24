import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  AlertTriangle,
  ArrowLeftRight,
  ArrowUp,
  CheckCircle2,
  Loader2,
  Palette,
  Plus,
  RefreshCw,
  Search,
  Sparkles,
  Square,
  Undo2,
  X,
} from 'lucide-react';
import {
  createDefaultMoodboardCurationRequest,
  getBoardReferencedAssetIDs,
  isLightHex,
} from '@charkle/shared';
import type {
  AssetRecord,
  MoodboardAgentStep,
  MoodboardDocument,
  MoodboardProposal,
  ScoredAsset,
  UUID,
} from '@charkle/shared';
import { apiClient, thumbnailURL } from '../../api/client';
import {
  CandidateGridSkeleton,
  DisclosureGroup,
  SegmentedControl,
  useDelayedFlag,
} from '../../design-system';
import { Button } from '../../design-system/Button';
import { AGENT_PHASE_META } from './palettes';

export type MoodboardDrawerTab = 'candidates' | 'curator';

const DRAWER_TABS: ReadonlyArray<{ id: MoodboardDrawerTab; label: string }> = [
  { id: 'candidates', label: '候选替换' },
  { id: 'curator', label: 'AI 策展' },
];

const QUICK_REFINEMENT_CHIPS: ReadonlyArray<{ label: string; instruction: string }> = [
  {
    label: '更统一色调',
    instruction: '统一当前画布整体色调与光影氛围，替换或移除色温突兀的素材',
  },
  {
    label: '精简为精选',
    instruction: '严格审视当前画布，精简为最具代表性的精选参考图，去除重复与偏弱的卡片',
  },
  {
    label: '补充更多视角',
    instruction: '保留现有核心素材，从素材库补充不同景别、构图与材质细节的更多视角',
  },
];

export interface CandidatePoolPanelProps {
  open: boolean;
  activeTab: MoodboardDrawerTab;
  onChangeTab: (tab: MoodboardDrawerTab) => void;
  document: MoodboardDocument;
  assetsByID: Record<UUID, AssetRecord>;
  allLibraryAssets: AssetRecord[];
  cacheBustVersion: number;
  swappingNodeID: UUID | null;
  candidatePool: ScoredAsset[];
  loadingCandidates: boolean;
  canUndo: boolean;
  extractingPalette: boolean;
  onClose: () => void;
  onCancelSwap: () => void;
  onRefreshCandidates: (seedAssetID: UUID) => void;
  onSwapWithAsset: (nodeID: UUID, newAssetID: UUID) => void;
  onAppendAsset: (assetID: UUID) => void;
  onReextractPalette: () => void;
  onCopyHex: (hex: string) => void;
  onSearchColor: (hex: string) => void;
  onApplyCuratedProposal: (proposal: MoodboardProposal) => void;
  onUndo: () => void;
}

export const CandidatePoolPanel: React.FC<CandidatePoolPanelProps> = ({
  open,
  activeTab,
  onChangeTab,
  document,
  assetsByID,
  allLibraryAssets,
  cacheBustVersion,
  swappingNodeID,
  candidatePool,
  loadingCandidates,
  canUndo,
  extractingPalette,
  onClose,
  onCancelSwap,
  onRefreshCandidates,
  onSwapWithAsset,
  onAppendAsset,
  onReextractPalette,
  onCopyHex,
  onSearchColor,
  onApplyCuratedProposal,
  onUndo,
}) => {
  const [filterQuery, setFilterQuery] = useState('');
  const [prefersReducedMotion, setPrefersReducedMotion] = useState(false);

  // In-canvas AI Curator local state
  const [refinementDraft, setRefinementDraft] = useState('');
  const [isRefining, setIsRefining] = useState(false);
  const [refinementSteps, setRefinementSteps] = useState<MoodboardAgentStep[]>([]);
  const [refinementSummary, setRefinementSummary] = useState<string | null>(null);
  const [refinementError, setRefinementError] = useState<string | null>(null);
  const [traceOpen, setTraceOpen] = useState(false);
  const [copiedHex, setCopiedHex] = useState<string | null>(null);
  const refineAbortRef = useRef<AbortController | null>(null);

  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return;
    const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
    const sync = () => setPrefersReducedMotion(mq.matches);
    sync();
    mq.addEventListener('change', sync);
    return () => mq.removeEventListener('change', sync);
  }, []);

  // Cancel any in-flight curator stream when switching boards or unmounting
  useEffect(() => {
    refineAbortRef.current?.abort();
    refineAbortRef.current = null;
    setIsRefining(false);
    setRefinementSteps([]);
    setRefinementSummary(null);
    setRefinementError(null);
    setTraceOpen(false);
  }, [document.id]);

  useEffect(() => {
    return () => {
      refineAbortRef.current?.abort();
      refineAbortRef.current = null;
    };
  }, []);

  const boardAssetIDsList = useMemo(() => getBoardReferencedAssetIDs(document), [document]);
  const boardAssetIDs = useMemo(() => new Set(boardAssetIDsList), [boardAssetIDsList]);

  const swappingAsset = useMemo(() => {
    if (!swappingNodeID) return null;
    const node = document.nodes.find((n) => n.id === swappingNodeID);
    if (!node || node.kind.type !== 'assetRef') return null;
    return assetsByID[node.kind.assetID] ?? null;
  }, [swappingNodeID, document.nodes, assetsByID]);

  // Auto-load initial replacement candidates when opening the candidates tab if empty
  useEffect(() => {
    if (!open || activeTab !== 'candidates' || candidatePool.length > 0 || loadingCandidates) return;
    const firstAssetID = boardAssetIDsList[0];
    if (firstAssetID) {
      onRefreshCandidates(firstAssetID);
    }
  }, [open, activeTab, candidatePool.length, loadingCandidates, boardAssetIDsList, onRefreshCandidates]);

  // Combine ranked replacement candidates + document.candidateAssetIDs + library fallback (up to 40)
  const displayItems = useMemo<ScoredAsset[]>(() => {
    const seen = new Set<UUID>();
    const list: ScoredAsset[] = [];

    for (const item of candidatePool) {
      if (boardAssetIDs.has(item.asset.id) || seen.has(item.asset.id)) continue;
      seen.add(item.asset.id);
      list.push(item);
    }

    for (const id of document.candidateAssetIDs) {
      if (boardAssetIDs.has(id) || seen.has(id)) continue;
      const asset = assetsByID[id];
      if (!asset || asset.isTrashed) continue;
      seen.add(id);
      list.push({ asset, score: 0.72, matchReasons: ['候选素材'] });
    }

    // Pad up to 36 from non-trashed library assets so the pool is always immediately usable
    if (list.length < 24) {
      for (const asset of allLibraryAssets) {
        if (list.length >= 36) break;
        if (asset.isTrashed || boardAssetIDs.has(asset.id) || seen.has(asset.id)) continue;
        seen.add(asset.id);
        list.push({ asset, score: 0.45, matchReasons: ['素材库推荐'] });
      }
    }

    const q = filterQuery.trim().toLowerCase();
    const filtered = q
      ? list.filter(
          (item) =>
            item.asset.title.toLowerCase().includes(q) ||
            item.asset.tags.some((t) => t.toLowerCase().includes(q)) ||
            item.matchReasons.some((r) => r.toLowerCase().includes(q)),
        )
      : list;

    return filtered.slice(0, 40);
  }, [candidatePool, document.candidateAssetIDs, assetsByID, allLibraryAssets, boardAssetIDs, filterQuery]);

  const refreshSeedID =
    swappingAsset?.id ?? boardAssetIDsList[0] ?? allLibraryAssets[0]?.id;

  const showCandidateSkeleton = useDelayedFlag(
    loadingCandidates && displayItems.length === 0,
    300,
    500,
  );
  const showRefreshBusy = useDelayedFlag(loadingCandidates && displayItems.length > 0, 300, 500);

  const pushStep = useCallback((step: MoodboardAgentStep) => {
    setRefinementSteps((prev) => {
      const idx = prev.findIndex((existing) => existing.id === step.id);
      if (idx >= 0) {
        const next = [...prev];
        next[idx] = step;
        return next;
      }
      return [...prev, step];
    });
  }, []);

  const handleStopRefine = useCallback(() => {
    refineAbortRef.current?.abort();
    refineAbortRef.current = null;
    setIsRefining(false);
  }, []);

  const handleRunRefinement = useCallback(
    async (instructionRaw: string) => {
      const instruction = instructionRaw.trim();
      if (!instruction || isRefining) return;

      refineAbortRef.current?.abort();
      const controller = new AbortController();
      refineAbortRef.current = controller;

      setIsRefining(true);
      setRefinementError(null);
      setRefinementSteps([]);
      setTraceOpen(true);

      const lockedAssetIDs = document.nodes
        .filter((n) => n.isLocked && n.kind.type === 'assetRef')
        .map((n) => (n.kind.type === 'assetRef' ? n.kind.assetID : ''))
        .filter((id): id is UUID => Boolean(id));

      const req = createDefaultMoodboardCurationRequest({
        prompt: document.title || instruction,
        seedAssetIDs: boardAssetIDsList.slice(0, 6),
        targetPalette: document.extractedPalette.slice(0, 3),
        preferredCount: Math.max(6, Math.min(16, boardAssetIDsList.length || 10)),
        candidateCount: 28,
        useFreeformLayout: true,
        includeCuratorNotes: true,
        lockedAssetIDs,
        existingBoard: document,
        refinementInstruction: instruction,
      });

      try {
        const proposal = await apiClient.curateMoodboard(
          req,
          (step) => pushStep(step),
          controller.signal,
        );
        if (controller.signal.aborted) return;

        if (proposal.agentTrace.length > 0) {
          setRefinementSteps(proposal.agentTrace);
        }
        setRefinementSummary(proposal.curatedSummary || '已完成画布微调');
        setTraceOpen(false);
        setRefinementDraft('');
        onApplyCuratedProposal(proposal);
      } catch (err) {
        if ((err as Error).name === 'AbortError') {
          return;
        }
        setRefinementError(err instanceof Error ? err.message : '微调失败，请重试');
      } finally {
        if (refineAbortRef.current === controller) {
          refineAbortRef.current = null;
        }
        setIsRefining(false);
      }
    },
    [document, boardAssetIDsList, isRefining, pushStep, onApplyCuratedProposal],
  );

  const handleCopySwatch = (hex: string) => {
    const upper = hex.toUpperCase();
    onCopyHex(upper);
    setCopiedHex(upper);
    window.setTimeout(() => {
      setCopiedHex((cur) => (cur === upper ? null : cur));
    }, 1100);
  };

  return (
    <aside
      aria-label="情绪板侧栏"
      aria-hidden={!open}
      inert={!open ? true : undefined}
      className={[
        'absolute top-0 right-0 bottom-0 z-30 w-[300px] h-full border-l border-[var(--border-hairline)] bg-[var(--bg-inspector)] shadow-xl flex flex-col select-none',
        'transition-[transform,opacity]',
        open ? 'pointer-events-auto opacity-100' : 'pointer-events-none opacity-0',
      ].join(' ')}
      style={{
        transitionDuration: open
          ? 'var(--duration-drawer, 300ms)'
          : 'var(--duration-exit-md, 170ms)',
        transitionTimingFunction: open
          ? 'var(--ease-drawer, cubic-bezier(0.32, 0.72, 0, 1))'
          : 'var(--ease-out, cubic-bezier(0.23, 1, 0.32, 1))',
        transform: open
          ? 'translate3d(0, 0, 0)'
          : prefersReducedMotion
            ? 'translate3d(0, 0, 0)'
            : 'translate3d(100%, 0, 0)',
      }}
    >
      {/* Top Tab Switcher + Close */}
      <div className="px-3 py-2.5 border-b border-[var(--border-hairline)] flex items-center gap-2 shrink-0">
        <SegmentedControl
          ariaLabel="侧栏视图"
          size="sm"
          fullWidth
          options={DRAWER_TABS}
          value={activeTab}
          onChange={onChangeTab}
          className="flex-1"
        />
        <button
          type="button"
          onClick={onClose}
          aria-label="关闭侧栏"
          className="charkle-pressable w-7 h-7 rounded-[var(--radius-chip)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0"
        >
          <X size={14} />
        </button>
      </div>

      {activeTab === 'candidates' ? (
        <>
          {/* Candidate Subheader & Refresh */}
          <div className="px-3 pt-2.5 pb-1 flex items-center justify-between gap-2 shrink-0">
            <span className="text-[11px] text-[var(--text-secondary)] truncate">
              {showRefreshBusy
                ? '正在更新候选…'
                : swappingNodeID
                  ? '点击卡片替换当前选中项'
                  : `${displayItems.length} 项候选素材`}
            </span>
            {refreshSeedID && (
              <button
                type="button"
                onClick={() => onRefreshCandidates(refreshSeedID)}
                disabled={loadingCandidates}
                title="刷新候选"
                className="charkle-pressable h-6 px-1.5 rounded-[var(--radius-chip)] inline-flex items-center gap-1 text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer disabled:opacity-40"
              >
                <RefreshCw size={11.5} className={loadingCandidates ? 'animate-spin' : ''} />
                刷新
              </button>
            )}
          </div>

          {/* Active Swap Target Banner */}
          {swappingNodeID && (
            <div className="mx-3 mt-1.5 p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--accent-soft)] border border-[var(--accent-ring)] flex items-center gap-2.5 shrink-0">
              {swappingAsset && (
                <img
                  src={thumbnailURL(swappingAsset.id, 'grid520', cacheBustVersion)}
                  alt={swappingAsset.title}
                  className="w-10 h-10 rounded-[6px] object-cover shrink-0 bg-[var(--bg-subtle)]"
                />
              )}
              <div className="min-w-0 flex-1">
                <div className="text-[11.5px] font-semibold text-[var(--accent)]">
                  替换当前卡片
                </div>
                <div className="text-[11px] text-[var(--text-secondary)] truncate">
                  {swappingAsset?.title ?? '已选画布卡片'}
                </div>
              </div>
              <Button variant="ghost" size="xs" onClick={onCancelSwap}>
                取消
              </Button>
            </div>
          )}

          {/* Search filter */}
          <div className="px-3 pt-2 pb-2 shrink-0">
            <div className="relative flex items-center">
              <Search
                size={13}
                className="absolute left-2.5 text-[var(--text-tertiary)] pointer-events-none"
              />
              <input
                type="search"
                value={filterQuery}
                onChange={(e) => setFilterQuery(e.target.value)}
                placeholder="筛选标题或标签…"
                className="w-full h-8 pl-8 pr-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none focus:border-[var(--accent)]"
              />
            </div>
          </div>

          {/* Grid */}
          <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll px-3 pb-4">
            {showCandidateSkeleton ? (
              <CandidateGridSkeleton count={6} className="pt-1" />
            ) : loadingCandidates && displayItems.length === 0 ? (
              <div className="py-12" aria-busy="true" />
            ) : displayItems.length === 0 ? (
              <div className="py-12 text-center text-[12px] text-[var(--text-secondary)]">
                暂无候选素材
              </div>
            ) : (
              <div className="grid grid-cols-2 gap-2 pt-1">
                {displayItems.map((item) => (
                  <div
                    key={item.asset.id}
                    draggable
                    onDragStart={(e) => {
                      const payload = JSON.stringify([item.asset.id]);
                      e.dataTransfer.setData('application/x-charkle-asset-ids', payload);
                      e.dataTransfer.setData('application/x-charkle-assets', payload);
                      e.dataTransfer.effectAllowed = 'copy';
                    }}
                    className="group/cand relative rounded-[var(--radius-settings-inner)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)]"
                  >
                    <div className="aspect-[4/3] w-full overflow-hidden bg-[var(--bg-subtle)]">
                      <img
                        src={thumbnailURL(item.asset.id, 'grid520', cacheBustVersion)}
                        alt={item.asset.title}
                        loading="lazy"
                        className="w-full h-full object-cover charkle-media-zoom"
                      />
                    </div>

                    {/* Hover / Focus quick button */}
                    <div className="absolute inset-0 bg-black/0 group-hover/cand:bg-black/32 group-focus-within/cand:bg-black/32 transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)] flex items-center justify-center p-2">
                      {swappingNodeID ? (
                        <button
                          type="button"
                          onClick={() => onSwapWithAsset(swappingNodeID, item.asset.id)}
                          className="charkle-pressable opacity-0 group-hover/cand:opacity-100 group-focus-within/cand:opacity-100 transition-opacity duration-[var(--duration-press,120ms)] ease-[var(--ease-out)] inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-[var(--accent)] text-white text-[11px] font-medium shadow-md cursor-pointer"
                        >
                          <ArrowLeftRight size={11} />
                          替换此图
                        </button>
                      ) : (
                        <button
                          type="button"
                          onClick={() => onAppendAsset(item.asset.id)}
                          className="charkle-pressable opacity-0 group-hover/cand:opacity-100 group-focus-within/cand:opacity-100 transition-opacity duration-[var(--duration-press,120ms)] ease-[var(--ease-out)] inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-[#141517]/88 text-white text-[11px] font-medium shadow-md cursor-pointer"
                        >
                          <Plus size={11} />
                          追加到画布
                        </button>
                      )}
                    </div>

                    <div className="px-2 py-1.5">
                      <div className="text-[11px] font-medium text-[var(--text-primary)] truncate">
                        {item.asset.title}
                      </div>
                      <div className="text-[10px] text-[var(--text-tertiary)] truncate">
                        {item.matchReasons[0] ?? `${Math.round(item.score * 100)}% 契合`}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        </>
      ) : (
        /* AI Curator & Palette Re-Extract Tab */
        <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-3 flex flex-col gap-3">
          {/* Board Palette Card */}
          <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-3 flex flex-col gap-2.5">
            <div className="flex items-center justify-between gap-2">
              <div className="flex items-center gap-1.5 text-[12px] font-semibold text-[var(--text-primary)]">
                <Palette size={13.5} className="text-[var(--accent)] shrink-0" />
                <span>画板配色</span>
              </div>
              <Button
                variant="secondary"
                size="xs"
                loading={extractingPalette}
                disabled={boardAssetIDsList.length === 0}
                onClick={onReextractPalette}
              >
                <RefreshCw size={11.5} />
                重新提取配色
              </Button>
            </div>

            {document.extractedPalette.length > 0 ? (
              <div className="grid grid-cols-2 gap-1.5">
                {document.extractedPalette.slice(0, 7).map((c) => {
                  const hex = c.hex.toUpperCase();
                  const light = isLightHex(hex);
                  return (
                    <button
                      key={hex}
                      type="button"
                      onClick={() => handleCopySwatch(hex)}
                      onContextMenu={(e) => {
                        e.preventDefault();
                        onSearchColor(hex);
                      }}
                      title={`点击复制 ${hex}，右键按此色筛选`}
                      className="charkle-pressable flex items-center gap-2 px-2 py-1.5 rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)] cursor-pointer text-left"
                    >
                      <span
                        className="w-4 h-4 rounded-[4px] shrink-0"
                        style={{
                          backgroundColor: hex,
                          boxShadow: light
                            ? 'inset 0 0 0 1px rgba(0,0,0,0.14)'
                            : 'inset 0 0 0 1px rgba(255,255,255,0.18)',
                        }}
                      />
                      <span className="text-[11px] font-mono text-[var(--text-primary)] truncate tabular-nums">
                        {copiedHex === hex ? '已复制' : hex}
                      </span>
                    </button>
                  );
                })}
              </div>
            ) : (
              <div className="text-[11.5px] text-[var(--text-tertiary)] py-1">
                添加图片后可提取画板主色调
              </div>
            )}
          </section>

          {/* In-Canvas AI Curator Card */}
          <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-3 flex flex-col gap-2.5">
            <div className="flex items-center justify-between gap-2">
              <div className="flex items-center gap-1.5 text-[12px] font-semibold text-[var(--text-primary)]">
                <Sparkles size={13.5} className="text-[var(--accent)] shrink-0" />
                <span>AI 策展助手</span>
              </div>
              {canUndo && !isRefining && (
                <button
                  type="button"
                  onClick={onUndo}
                  title="撤销上一步 (⌘Z)"
                  className="charkle-pressable inline-flex items-center gap-1 px-1.5 py-0.5 rounded-[6px] text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
                >
                  <Undo2 size={11} />
                  撤销
                </button>
              )}
            </div>

            {/* Refinement prompt input */}
            <form
              onSubmit={(e) => {
                e.preventDefault();
                void handleRunRefinement(refinementDraft);
              }}
              className="flex items-center gap-1.5"
            >
              <input
                type="text"
                value={refinementDraft}
                disabled={isRefining}
                onChange={(e) => setRefinementDraft(e.target.value)}
                placeholder="输入微调指令…"
                className="flex-1 min-w-0 h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none focus:border-[var(--accent)] disabled:opacity-60"
              />
              {isRefining ? (
                <button
                  type="button"
                  onClick={handleStopRefine}
                  aria-label="停止微调"
                  title="停止"
                  className="charkle-pressable w-8 h-8 rounded-[var(--radius-settings-inner)] inline-flex items-center justify-center bg-[var(--danger-soft)] text-[var(--danger)] hover:bg-[var(--danger)] hover:text-white cursor-pointer shrink-0 transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]"
                >
                  <Square size={11} fill="currentColor" />
                </button>
              ) : (
                <button
                  type="submit"
                  disabled={!refinementDraft.trim()}
                  aria-label="执行微调"
                  title="发送"
                  className="charkle-pressable w-8 h-8 rounded-[var(--radius-settings-inner)] inline-flex items-center justify-center bg-[var(--accent)] text-white hover:bg-[var(--accent-hover)] disabled:opacity-35 disabled:cursor-not-allowed cursor-pointer shrink-0 transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]"
                >
                  <ArrowUp size={13} strokeWidth={2.4} />
                </button>
              )}
            </form>

            {/* 3 Quick Refinement Chips */}
            <div className="flex flex-wrap gap-1.5">
              {QUICK_REFINEMENT_CHIPS.map((chip) => (
                <button
                  key={chip.label}
                  type="button"
                  disabled={isRefining}
                  onClick={() => void handleRunRefinement(chip.instruction)}
                  className="charkle-pressable px-2.5 py-1 rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)] text-[11.5px] font-medium text-[var(--text-primary)] cursor-pointer disabled:opacity-45 disabled:cursor-not-allowed transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]"
                >
                  {chip.label}
                </button>
              ))}
            </div>

            {/* Error state */}
            {refinementError && (
              <div className="p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--danger-soft)] text-[var(--danger)] text-[11.5px] flex items-start gap-2">
                <AlertTriangle size={13} className="shrink-0 mt-0.5" />
                <span className="leading-snug charkle-wrap-anywhere">{refinementError}</span>
              </div>
            )}

            {/* Live Streaming Progress Trace */}
            {isRefining && (
              <div className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] p-2.5 flex flex-col gap-2">
                {refinementSteps.length === 0 ? (
                  <div className="flex items-center gap-2 text-[11.5px] text-[var(--text-secondary)]">
                    <Loader2 size={12.5} className="animate-spin text-[var(--accent)] shrink-0" />
                    <span>正在分析当前画布…</span>
                  </div>
                ) : (
                  refinementSteps.map((step) => {
                    const meta = AGENT_PHASE_META[step.phase];
                    return (
                      <div key={step.id} className="flex items-start gap-2 text-[11.5px]">
                        <span className="mt-0.5 shrink-0">
                          {step.status === 'running' ? (
                            <Loader2 size={12} className="animate-spin text-[var(--accent)]" />
                          ) : step.status === 'warning' ? (
                            <AlertTriangle size={12} className="text-[var(--warning)]" />
                          ) : (
                            <CheckCircle2 size={12} className="text-[var(--success)]" />
                          )}
                        </span>
                        <div className="min-w-0 flex-1">
                          <div className="flex items-center gap-1.5 flex-wrap">
                            <span className="px-1.5 py-0.5 rounded-[5px] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[10px] font-medium text-[var(--text-secondary)]">
                              {meta?.shortLabel ?? step.phase}
                            </span>
                            <span className="font-medium text-[var(--text-primary)] leading-snug">
                              {step.title}
                            </span>
                          </div>
                          {step.detail && (
                            <p className="text-[11px] text-[var(--text-secondary)] mt-0.5 leading-snug">
                              {step.detail}
                            </p>
                          )}
                        </div>
                      </div>
                    );
                  })
                )}
              </div>
            )}

            {/* Completed Summary + Collapsible Trace */}
            {!isRefining && refinementSummary && (
              <div className="rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] p-2.5 flex flex-col gap-2">
                <p className="text-[11.5px] text-[var(--text-secondary)] leading-relaxed">
                  {refinementSummary}
                </p>
                {refinementSteps.length > 0 && (
                  <DisclosureGroup
                    open={traceOpen}
                    onOpenChange={setTraceOpen}
                    headerClassName="-mx-1 px-1 py-0.5"
                    label={
                      <span className="text-[11px] font-medium text-[var(--text-tertiary)]">
                        策展步骤 ({refinementSteps.length})
                      </span>
                    }
                  >
                    <div className="pt-1.5 flex flex-col gap-1.5 border-t border-[var(--border-hairline)]">
                      {refinementSteps.map((step) => {
                        const meta = AGENT_PHASE_META[step.phase];
                        return (
                          <div key={step.id} className="flex items-start gap-1.5 text-[11px]">
                            <CheckCircle2 size={11} className="text-[var(--success)] mt-0.5 shrink-0" />
                            <div className="min-w-0 flex-1">
                              <span className="text-[var(--text-tertiary)] mr-1">
                                [{meta?.shortLabel ?? step.phase}]
                              </span>
                              <span className="text-[var(--text-primary)]">{step.title}</span>
                              {step.detail && (
                                <div className="text-[10.5px] text-[var(--text-secondary)] mt-0.5">
                                  {step.detail}
                                </div>
                              )}
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  </DisclosureGroup>
                )}
              </div>
            )}
          </section>
        </div>
      )}
    </aside>
  );
};
