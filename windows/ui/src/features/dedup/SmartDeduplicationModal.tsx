import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  ArrowSync16Regular,
  Board16Regular,
  Checkmark16Regular,
  CheckmarkCircle16Filled,
  Crown16Filled,
  Delete16Regular,
  Dismiss16Regular,
  Eye16Regular,
  Folder16Regular,
  Sparkle16Regular,
  Warning16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import { Button, ModalShell, SegmentedControl, formatBytes } from '../../design-system';
import { useCoordinatorStore, useLibraryStore, useMoodboardStore } from '../../stores';
import {
  buildFolderTree,
  flattenFolderTree,
  type DeduplicationResolutionPlan,
  type DeduplicationScanReport,
  type DeduplicationScanScope,
  type DeduplicationSensitivity,
  type DuplicateDisposalMode,
  type DuplicateGroup,
  type DuplicateMatchKind,
  type MediaKind,
} from '../../types/domain';

type MediaFilterKey =
  | 'all'
  | 'raster'
  | 'video'
  | 'audio'
  | 'designFile'
  | 'webBookmark'
  | 'document'
  | 'model3D';

const MEDIA_FILTER_TABS: Array<{
  key: MediaFilterKey;
  label: string;
  kinds: MediaKind[] | null;
}> = [
  { key: 'all', label: '全部', kinds: null },
  { key: 'raster', label: '图片与动图', kinds: ['image', 'animatedImage'] },
  { key: 'video', label: '视频', kinds: ['video'] },
  { key: 'audio', label: '音频', kinds: ['audio'] },
  { key: 'designFile', label: '设计源文件', kinds: ['designFile'] },
  { key: 'webBookmark', label: '网页书签', kinds: ['webBookmark'] },
  { key: 'document', label: '文档', kinds: ['document'] },
  { key: 'model3D', label: '3D 模型', kinds: ['model3D'] },
];

const SENSITIVITY_OPTIONS: Array<{ value: DeduplicationSensitivity; label: string }> = [
  { value: 'strict', label: '精确' },
  { value: 'balanced', label: '智能平衡' },
  { value: 'relaxed', label: '宽松' },
];

function matchKindLabel(kind: DuplicateMatchKind): string {
  switch (kind) {
    case 'exactBinary':
      return '完全相同';
    case 'nearIdentical':
      return '同画面不同版本';
    case 'canonicalLink':
      return '同一链接 / 帖子';
    case 'normalizedText':
      return '文本内容一致';
    case 'audioWaveform':
      return '同音频不同码率/格式';
  }
}

function mediaFilterMatchesKind(filter: MediaFilterKey, kind: MediaKind): boolean {
  if (filter === 'all') return true;
  if (filter === 'raster') return kind === 'image' || kind === 'animatedImage';
  return kind === filter;
}

function formatDimensions(w: number, h: number): string | null {
  if (w > 0 && h > 0) return `${w} × ${h}`;
  return null;
}

/**
 * Fluent 2 Classical Non-AI Multi-Media Smart Deduplication Review Modal.
 * Mounted strictly at `z-[115]` — below `QuickLookOverlay` (`z-[130]`) so users can
 * inspect any candidate full-size in Quick Look without closing or losing scan state.
 */
export const SmartDeduplicationModal: React.FC = () => {
  const open = useCoordinatorStore((s) => s.dedupOpen);
  const initialScope = useCoordinatorStore((s) => s.dedupInitialScope);
  const closeDeduplication = useCoordinatorStore((s) => s.closeDeduplication);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const quickLookAssetId = useCoordinatorStore((s) => s.quickLookAssetId);
  const destination = useCoordinatorStore((s) => s.destination);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const folders = useLibraryStore((s) => s.folders);
  const refreshAll = useLibraryStore((s) => s.refreshAll);
  const fetchBoards = useMoodboardStore((s) => s.fetchBoards);

  const flatFolders = useMemo(() => flattenFolderTree(buildFolderTree(folders)), [folders]);
  const folderNameById = useMemo(() => {
    const map = new Map<string, string>();
    for (const f of folders) map.set(f.id, f.name);
    return map;
  }, [folders]);

  const [scope, setScope] = useState<DeduplicationScanScope>({ type: 'allActive' });
  const [sensitivity, setSensitivity] = useState<DeduplicationSensitivity>('balanced');
  const [mediaFilter, setMediaFilter] = useState<MediaFilterKey>('all');
  const [scanning, setScanning] = useState(false);
  const [scanError, setScanError] = useState<string | null>(null);
  const [report, setReport] = useState<DeduplicationScanReport | null>(null);

  const [selectedGroupId, setSelectedGroupId] = useState<string | null>(null);
  const [includedGroupIds, setIncludedGroupIds] = useState<Record<string, boolean>>({});
  const [keeperOverrides, setKeeperOverrides] = useState<Record<string, string>>({});

  const [mergeMetadata, setMergeMetadata] = useState(true);
  const [disposal, setDisposal] = useState<DuplicateDisposalMode>('moveToTrash');
  const [resolving, setResolving] = useState(false);
  const [confirmPermanentOpen, setConfirmPermanentOpen] = useState(false);

  const runScan = useCallback(
    async (nextScope: DeduplicationScanScope, nextSensitivity: DeduplicationSensitivity) => {
      setScanning(true);
      setScanError(null);
      try {
        const result = await getTransport().scanDuplicates(nextScope, nextSensitivity, null);
        setReport(result);
        const nextIncluded: Record<string, boolean> = {};
        for (const g of result.groups) {
          nextIncluded[g.id] = true;
        }
        setIncludedGroupIds(nextIncluded);
        setKeeperOverrides({});
        setSelectedGroupId(result.groups[0]?.id ?? null);
      } catch (err) {
        setScanError(err instanceof Error ? err.message : String(err));
        setReport(null);
      } finally {
        setScanning(false);
      }
    },
    [],
  );

  useEffect(() => {
    if (!open) {
      setConfirmPermanentOpen(false);
      return;
    }
    setScope(initialScope);
    setMediaFilter('all');
    setDisposal('moveToTrash');
    setMergeMetadata(true);
    void runScan(initialScope, sensitivity);
    // Only auto-run on modal open / initialScope change
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, initialScope]);

  // Escape closes Dedup modal ONLY when Quick Look and Confirm dialog are NOT open on top
  useEffect(() => {
    if (!open) return;
    const handleKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      if (quickLookAssetId || confirmPermanentOpen) return;
      e.preventDefault();
      e.stopPropagation();
      closeDeduplication();
    };
    window.addEventListener('keydown', handleKey);
    return () => window.removeEventListener('keydown', handleKey);
  }, [open, quickLookAssetId, confirmPermanentOpen, closeDeduplication]);

  const allGroups = useMemo(() => report?.groups ?? [], [report]);

  const filterCounts = useMemo(() => {
    const counts: Record<MediaFilterKey, number> = {
      all: allGroups.length,
      raster: 0,
      video: 0,
      audio: 0,
      designFile: 0,
      webBookmark: 0,
      document: 0,
      model3D: 0,
    };
    for (const g of allGroups) {
      if (g.primaryMediaKind === 'image' || g.primaryMediaKind === 'animatedImage') {
        counts.raster += 1;
      } else if (g.primaryMediaKind in counts) {
        counts[g.primaryMediaKind as MediaFilterKey] += 1;
      }
    }
    return counts;
  }, [allGroups]);

  const visibleGroups = useMemo(
    () => allGroups.filter((g) => mediaFilterMatchesKind(mediaFilter, g.primaryMediaKind)),
    [allGroups, mediaFilter],
  );

  useEffect(() => {
    if (visibleGroups.length === 0) {
      setSelectedGroupId(null);
      return;
    }
    if (!selectedGroupId || !visibleGroups.some((g) => g.id === selectedGroupId)) {
      setSelectedGroupId(visibleGroups[0].id);
    }
  }, [visibleGroups, selectedGroupId]);

  const activeGroup: DuplicateGroup | null = useMemo(
    () => visibleGroups.find((g) => g.id === selectedGroupId) ?? visibleGroups[0] ?? null,
    [visibleGroups, selectedGroupId],
  );

  const effectiveKeeperId = useCallback(
    (group: DuplicateGroup): string =>
      keeperOverrides[group.id] ?? group.recommendedKeepAssetID,
    [keeperOverrides],
  );

  const activePlans = useMemo(() => {
    const plans: DeduplicationResolutionPlan[] = [];
    let removeCount = 0;
    let reclaimBytes = 0;

    for (const group of visibleGroups) {
      if (!includedGroupIds[group.id]) continue;
      const keepId = effectiveKeeperId(group);
      const removeCandidates = group.candidates.filter((c) => c.asset.id !== keepId);
      if (removeCandidates.length === 0) continue;
      plans.push({
        keepAssetID: keepId,
        removeAssetIDs: removeCandidates.map((c) => c.asset.id),
      });
      removeCount += removeCandidates.length;
      reclaimBytes += removeCandidates.reduce(
        (sum, c) => sum + Math.max(0, c.asset.fileSizeBytes),
        0,
      );
    }

    return { plans, removeCount, reclaimBytes };
  }, [visibleGroups, includedGroupIds, effectiveKeeperId]);

  const executeCleanup = async () => {
    if (activePlans.plans.length === 0 || resolving) return;
    setResolving(true);
    setConfirmPermanentOpen(false);
    try {
      const result = await getTransport().resolveDuplicateGroups(
        activePlans.plans,
        disposal,
        mergeMetadata,
      );
      await Promise.all([refreshAll(destination), fetchBoards()]);

      const boardPart =
        result.updatedBoardCount > 0 ? `，无损改绑 ${result.updatedBoardCount} 块情绪板` : '';
      const modePart = disposal === 'moveToTrash' ? '已移入回收站' : '已彻底删除';
      pushToast({
        message: `去重完成：清理 ${result.resolvedGroupCount} 组共 ${result.removedAssetCount} 项重复素材（${modePart}，释放 ${formatBytes(result.reclaimedBytes)}${boardPart}）`,
        tone: 'success',
      });
      await runScan(scope, sensitivity);
    } catch (err) {
      pushToast({
        message: `清理重复素材失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setResolving(false);
    }
  };

  if (!open) return null;

  const transport = getTransport();
  const scopeSelectValue =
    scope.type === 'allActive'
      ? 'allActive'
      : scope.type === 'inbox'
        ? 'inbox'
        : `folder:${scope.folderID}`;

  return createPortal(
    <>
      <div
        role="dialog"
        aria-modal="true"
        aria-label="全媒体智能去重"
        data-testid="smart-dedup-modal"
        className="win-smoke-scrim win-dialog-backdrop fixed inset-0 z-[115] flex items-center justify-center p-5"
        onMouseDown={(e) => {
          if (e.target === e.currentTarget && !quickLookAssetId && !confirmPermanentOpen) {
            closeDeduplication();
          }
        }}
      >
        <div
          data-testid="smart-dedup-dialog-surface"
          onMouseDown={(e) => e.stopPropagation()}
          onClick={(e) => e.stopPropagation()}
          className="win-dialog-popup w-[min(1080px,94vw)] h-[min(740px,88vh)] rounded-[var(--win-radius-dialog)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-flyout)] shadow-[var(--shadow-modal)] flex flex-col overflow-hidden text-[var(--text-primary)]"
        >
          {/* Header */}
          <div className="px-5 py-3.5 border-b border-[var(--win-stroke-divider)] flex items-center justify-between gap-3 shrink-0">
            <div className="flex items-center gap-2.5 min-w-0">
              <div className="w-8 h-8 rounded-[var(--win-radius-control)] bg-[var(--accent-soft)] text-[var(--accent)] inline-flex items-center justify-center shrink-0">
                <Sparkle16Regular className="w-4 h-4" />
              </div>
              <div className="min-w-0">
                <h2 className="text-[15px] font-semibold leading-5 truncate">
                  全媒体智能去重
                </h2>
                <p className="text-[11.5px] text-[var(--text-secondary)] truncate">
                  纯本机确定性算法（零 AI / 零云端调用），按 8 类媒体严格分桶隔离，自动评选最高画质母版
                </p>
              </div>
            </div>

            <button
              type="button"
              aria-label="关闭智能去重"
              onClick={closeDeduplication}
              className="charkle-pressable w-8 h-8 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer shrink-0"
            >
              <Dismiss16Regular className="w-4 h-4" />
            </button>
          </div>

          {/* Controls Bar: Scope + Sensitivity + Rescan + Media Filter Chips */}
          <div className="px-5 py-3 border-b border-[var(--win-stroke-divider)] flex flex-col gap-2.5 shrink-0 bg-[var(--bg-subtle)]/40">
            <div className="flex flex-wrap items-center justify-between gap-2.5">
              <div className="flex flex-wrap items-center gap-2.5">
                <label className="inline-flex items-center gap-1.5 text-[12px] text-[var(--text-secondary)]">
                  <span>作用域</span>
                  <select
                    aria-label="去重扫描作用域"
                    value={scopeSelectValue}
                    onChange={(e) => {
                      const val = e.target.value;
                      const nextScope: DeduplicationScanScope =
                        val === 'allActive'
                          ? { type: 'allActive' }
                          : val === 'inbox'
                            ? { type: 'inbox' }
                            : {
                                type: 'folder',
                                folderID: val.slice('folder:'.length),
                                includeSubfolders: true,
                              };
                      setScope(nextScope);
                      void runScan(nextScope, sensitivity);
                    }}
                    className="win-input-elevation h-[30px] px-2.5 rounded-[var(--win-radius-control)] text-[12px] text-[var(--text-primary)] bg-[var(--win-control-fill)] outline-none max-w-[220px]"
                  >
                    <option value="allActive">全库活跃素材</option>
                    <option value="inbox">收件箱</option>
                    {flatFolders.map(({ folder, depth }) => (
                      <option key={folder.id} value={`folder:${folder.id}`}>
                        {'　'.repeat(Math.min(depth, 4))}
                        {folder.name}
                      </option>
                    ))}
                  </select>
                </label>

                <div className="flex items-center gap-1.5">
                  <span className="text-[12px] text-[var(--text-secondary)]">严格度</span>
                  <SegmentedControl
                    options={SENSITIVITY_OPTIONS}
                    value={sensitivity}
                    onChange={(next) => {
                      setSensitivity(next);
                      void runScan(scope, next);
                    }}
                    size="sm"
                    ariaLabel="去重严格度"
                  />
                </div>
              </div>

              <div className="flex items-center gap-2.5">
                {report && !scanning && (
                  <span className="text-[11.5px] text-[var(--text-secondary)] charkle-tabular">
                    已扫描 {report.scannedAssetCount} 项 · {report.groups.length} 组重复 · 耗时{' '}
                    {report.durationSeconds.toFixed(2)}s
                  </span>
                )}
                <Button
                  variant="standard"
                  size="xs"
                  disabled={scanning || resolving}
                  onClick={() => void runScan(scope, sensitivity)}
                >
                  <ArrowSync16Regular
                    className={`w-3.5 h-3.5 ${scanning ? 'animate-spin motion-reduce:animate-none' : ''}`}
                  />
                  <span>{scanning ? '扫描中…' : '重新扫描'}</span>
                </Button>
              </div>
            </div>

            {/* 7-Bucket Media Filter Chips */}
            <div className="flex items-center gap-1.5 overflow-x-auto charkle-scroll-hidden pb-0.5">
              {MEDIA_FILTER_TABS.map((tab) => {
                const count = filterCounts[tab.key];
                const active = mediaFilter === tab.key;
                return (
                  <button
                    key={tab.key}
                    type="button"
                    data-testid={`dedup-filter-${tab.key}`}
                    onClick={() => setMediaFilter(tab.key)}
                    className={[
                      'charkle-pressable h-7 px-2.5 rounded-full text-[11.5px] font-medium inline-flex items-center gap-1.5 cursor-pointer shrink-0 border transition-colors',
                      active
                        ? 'bg-[var(--accent)] text-[var(--accent-text)] border-transparent'
                        : 'bg-[var(--win-control-fill)] text-[var(--text-secondary)] border-[var(--win-stroke-control)] hover:text-[var(--text-primary)]',
                    ].join(' ')}
                  >
                    <span>{tab.label}</span>
                    {count > 0 && (
                      <span
                        className={[
                          'px-1.5 py-0.2 rounded-full text-[10.5px] leading-4 charkle-tabular',
                          active
                            ? 'bg-white/20 text-white'
                            : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)]',
                        ].join(' ')}
                      >
                        {count}
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          </div>

          {/* Main Split Body */}
          <div className="flex-1 min-h-0 flex overflow-hidden">
            {scanning ? (
              <div className="flex-1 flex flex-col items-center justify-center gap-2 text-[var(--text-secondary)]">
                <ArrowSync16Regular className="w-6 h-6 animate-spin text-[var(--accent)]" />
                <div className="text-[13px] font-medium text-[var(--text-primary)]">
                  正在计算视觉、波形与文档规范化指纹…
                </div>
                <div className="text-[12px]">首次扫描会自动建立本地指纹缓存，复扫瞬时完成</div>
              </div>
            ) : scanError ? (
              <div className="flex-1 flex flex-col items-center justify-center gap-2 px-6 text-center">
                <Warning16Regular className="w-6 h-6 text-[var(--danger)]" />
                <div className="text-[13px] font-medium text-[var(--danger)]">
                  扫描失败：{scanError}
                </div>
                <Button
                  variant="standard"
                  size="sm"
                  onClick={() => void runScan(scope, sensitivity)}
                >
                  重试扫描
                </Button>
              </div>
            ) : visibleGroups.length === 0 ? (
              <div className="flex-1 flex flex-col items-center justify-center gap-2 px-6 text-center">
                <CheckmarkCircle16Filled className="w-8 h-8 text-[var(--success)]" />
                <div className="text-[14px] font-semibold text-[var(--text-primary)]">
                  {allGroups.length === 0
                    ? '当前范围内没有发现重复素材'
                    : '该媒体类型下没有发现重复项'}
                </div>
                <div className="text-[12px] text-[var(--text-secondary)] max-w-[360px]">
                  {allGroups.length === 0
                    ? '你的素材库非常整洁。如需检出二次压缩或轻微裁边版本，可切换至「宽松」严格度再次扫描。'
                    : '可切换上方媒体筛选标签查看其他类型的重复组。'}
                </div>
              </div>
            ) : (
              <>
                {/* Left Group List */}
                <div className="w-[290px] shrink-0 border-r border-[var(--win-stroke-divider)] overflow-y-auto p-2.5 flex flex-col gap-1.5">
                  <div className="flex items-center justify-between px-1.5 pb-1 text-[11px] text-[var(--text-tertiary)]">
                    <span>重复组（{visibleGroups.length}）</span>
                    <button
                      type="button"
                      onClick={() => {
                        const allChecked = visibleGroups.every((g) => includedGroupIds[g.id]);
                        setIncludedGroupIds((prev) => {
                          const next = { ...prev };
                          for (const g of visibleGroups) {
                            next[g.id] = !allChecked;
                          }
                          return next;
                        });
                      }}
                      className="text-[var(--accent)] hover:underline cursor-pointer"
                    >
                      {visibleGroups.every((g) => includedGroupIds[g.id]) ? '全部取消' : '全选本页'}
                    </button>
                  </div>

                  {visibleGroups.map((group) => {
                    const selected = activeGroup?.id === group.id;
                    const checked = Boolean(includedGroupIds[group.id]);
                    const keepId = effectiveKeeperId(group);
                    const keepCand =
                      group.candidates.find((c) => c.asset.id === keepId) ?? group.candidates[0];
                    const reclaim = group.candidates
                      .filter((c) => c.asset.id !== keepId)
                      .reduce((s, c) => s + Math.max(0, c.asset.fileSizeBytes), 0);

                    return (
                      <div
                        key={group.id}
                        role="button"
                        tabIndex={0}
                        data-testid={`dedup-group-${group.id}`}
                        onClick={() => setSelectedGroupId(group.id)}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault();
                            setSelectedGroupId(group.id);
                          }
                        }}
                        className={[
                          'flex items-center gap-2.5 p-2 rounded-[var(--win-radius-card)] border cursor-pointer transition-colors text-left',
                          selected
                            ? 'bg-[var(--accent-soft)] border-[var(--accent)]/40'
                            : 'bg-[var(--win-layer-default)] border-[var(--win-stroke-card)] hover:bg-[var(--win-subtle-hover)]',
                        ].join(' ')}
                      >
                        <button
                          type="button"
                          role="checkbox"
                          aria-checked={checked}
                          aria-label={`选择清理该重复组：${keepCand.asset.title}`}
                          onClick={(e) => {
                            e.stopPropagation();
                            setIncludedGroupIds((prev) => ({
                              ...prev,
                              [group.id]: !prev[group.id],
                            }));
                          }}
                          className={[
                            'w-4 h-4 rounded-[4px] border inline-flex items-center justify-center shrink-0 cursor-pointer',
                            checked
                              ? 'bg-[var(--accent)] border-[var(--accent)] text-white'
                              : 'border-[var(--win-stroke-control)] bg-transparent',
                          ].join(' ')}
                        >
                          {checked && <Checkmark16Regular className="w-3 h-3" />}
                        </button>

                        <div className="w-11 h-11 rounded-[6px] overflow-hidden bg-[var(--bg-subtle)] border border-[var(--win-stroke-card)] shrink-0">
                          <img
                            src={transport.thumbnailUrl(keepCand.asset.id, 'grid520')}
                            alt={keepCand.asset.title}
                            className="w-full h-full object-cover"
                            loading="lazy"
                          />
                        </div>

                        <div className="flex-1 min-w-0">
                          <div className="text-[12.5px] font-medium truncate">
                            {keepCand.asset.title}
                          </div>
                          <div className="flex items-center gap-1.5 mt-0.5 text-[11px] text-[var(--text-secondary)]">
                            <span className="px-1.5 py-0.2 rounded bg-[var(--bg-subtle)] text-[10.5px]">
                              {matchKindLabel(group.matchKind)}
                            </span>
                            <span className="charkle-tabular">{group.candidates.length} 项</span>
                          </div>
                          <div className="text-[10.5px] text-[var(--text-tertiary)] mt-0.5 charkle-tabular">
                            可释放 {formatBytes(reclaim)}
                          </div>
                        </div>
                      </div>
                    );
                  })}
                </div>

                {/* Right Side-by-Side Comparison Grid */}
                <div className="flex-1 min-w-0 overflow-y-auto p-4 flex flex-col gap-3">
                  {activeGroup && (
                    <>
                      <div className="flex items-center justify-between gap-2">
                        <div className="flex items-center gap-2 min-w-0">
                          <span className="text-[13.5px] font-semibold">
                            {matchKindLabel(activeGroup.matchKind)}
                          </span>
                          <span className="text-[12px] text-[var(--text-secondary)] charkle-tabular">
                            相似度 {Math.round(activeGroup.similarityScore * 100)}% · 共{' '}
                            {activeGroup.candidates.length} 个版本
                          </span>
                        </div>
                        <span className="text-[11.5px] text-[var(--text-tertiary)]">
                          点击任意副本的「改为保留」可覆盖默认推荐
                        </span>
                      </div>

                      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                        {activeGroup.candidates.map((cand) => {
                          const keeperId = effectiveKeeperId(activeGroup);
                          const isKept = cand.asset.id === keeperId;
                          const dims = formatDimensions(
                            cand.asset.pixelWidth,
                            cand.asset.pixelHeight,
                          );
                          const folderLabel = cand.asset.folderID
                            ? folderNameById.get(cand.asset.folderID) ?? '文件夹'
                            : '收件箱';

                          return (
                            <div
                              key={cand.asset.id}
                              data-testid={`dedup-candidate-${cand.asset.id}`}
                              data-kept={isKept ? 'true' : 'false'}
                              className={[
                                'rounded-[var(--win-radius-card)] border p-3 flex flex-col gap-2.5 transition-colors',
                                isKept
                                  ? 'bg-[var(--accent-soft)]/55 border-[var(--accent)] ring-1 ring-[var(--accent)]/35'
                                  : 'bg-[var(--win-layer-default)] border-[var(--win-stroke-card)]',
                              ].join(' ')}
                            >
                              {/* Preview Thumbnail + Top Status Badge */}
                              <div className="relative h-[168px] rounded-[8px] overflow-hidden bg-[var(--bg-subtle)] border border-[var(--win-stroke-card)]">
                                <img
                                  src={transport.thumbnailUrl(cand.asset.id, 'grid520')}
                                  alt={cand.asset.title}
                                  className="w-full h-full object-contain"
                                />

                                <div className="absolute top-2 left-2 flex items-center gap-1.5">
                                  {isKept ? (
                                    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-[var(--accent)] text-white text-[11px] font-semibold shadow-sm">
                                      <Crown16Filled className="w-3 h-3" />
                                      <span>
                                        {cand.isRecommendedKeep ? '推荐保留' : '已选保留'}
                                      </span>
                                    </span>
                                  ) : (
                                    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-black/65 text-white text-[11px] font-medium">
                                      <Delete16Regular className="w-3 h-3" />
                                      <span>待清理副本</span>
                                    </span>
                                  )}
                                  {cand.isReferencedByBoard && (
                                    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-black/65 text-white text-[10.5px]">
                                      <Board16Regular className="w-3 h-3" />
                                      <span>情绪板引用</span>
                                    </span>
                                  )}
                                </div>

                                <button
                                  type="button"
                                  onClick={() => openQuickLook(cand.asset.id)}
                                  aria-label={`大图预览 ${cand.asset.title}`}
                                  className="charkle-pressable absolute bottom-2 right-2 h-7 px-2 rounded-[var(--win-radius-control)] bg-black/70 hover:bg-black/85 text-white text-[11px] font-medium inline-flex items-center gap-1 cursor-pointer"
                                >
                                  <Eye16Regular className="w-3.5 h-3.5" />
                                  <span>大图预览</span>
                                </button>
                              </div>

                              {/* Title + Technical Metadata */}
                              <div className="min-w-0">
                                <div
                                  className="text-[13px] font-medium truncate"
                                  title={cand.asset.title}
                                >
                                  {cand.asset.title}
                                </div>
                                <div className="mt-1 flex flex-wrap items-center gap-1.5 text-[11px] text-[var(--text-secondary)] charkle-tabular">
                                  <span className="px-1.5 py-0.5 rounded bg-[var(--bg-subtle)] font-medium text-[var(--text-primary)]">
                                    {cand.formatLabel}
                                  </span>
                                  {dims && <span>{dims}</span>}
                                  <span>{formatBytes(cand.asset.fileSizeBytes)}</span>
                                  <span className="inline-flex items-center gap-0.5 text-[var(--text-tertiary)]">
                                    <Folder16Regular className="w-3 h-3" />
                                    {folderLabel}
                                  </span>
                                </div>
                              </div>

                              {/* Quality Reason Badges */}
                              {cand.qualityReasons.length > 0 && (
                                <div className="flex flex-wrap gap-1">
                                  {cand.qualityReasons.map((reason) => (
                                    <span
                                      key={reason}
                                      className="px-1.5 py-0.5 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[10.5px] font-medium"
                                    >
                                      {reason}
                                    </span>
                                  ))}
                                </div>
                              )}

                              {/* Override Keeper Action */}
                              <div className="mt-auto pt-1 flex items-center justify-between gap-2">
                                <span className="text-[11px] text-[var(--text-tertiary)] truncate">
                                  {cand.asset.tags.length > 0
                                    ? `标签：${cand.asset.tags.slice(0, 3).join('、')}`
                                    : cand.asset.fileName}
                                </span>
                                {!isKept && (
                                  <Button
                                    variant="standard"
                                    size="xs"
                                    onClick={() =>
                                      setKeeperOverrides((prev) => ({
                                        ...prev,
                                        [activeGroup.id]: cand.asset.id,
                                      }))
                                    }
                                  >
                                    改为保留
                                  </Button>
                                )}
                              </div>
                            </div>
                          );
                        })}
                      </div>
                    </>
                  )}
                </div>
              </>
            )}
          </div>

          {/* Bottom Action Footer */}
          <div className="px-5 py-3 border-t border-[var(--win-stroke-divider)] bg-[var(--bg-subtle)]/40 flex flex-wrap items-center justify-between gap-3 shrink-0">
            <div className="flex flex-wrap items-center gap-4">
              <label className="inline-flex items-center gap-2 text-[12px] text-[var(--text-primary)] cursor-pointer select-none">
                <input
                  type="checkbox"
                  checked={mergeMetadata}
                  onChange={(e) => setMergeMetadata(e.target.checked)}
                  className="accent-[var(--accent)] w-3.5 h-3.5 cursor-pointer"
                />
                <span>合并元数据与情绪板引用</span>
              </label>

              <div className="inline-flex items-center gap-1.5 text-[12px]">
                <button
                  type="button"
                  onClick={() => setDisposal('moveToTrash')}
                  className={[
                    'px-2.5 py-1 rounded-[var(--win-radius-control)] border text-[11.5px] cursor-pointer',
                    disposal === 'moveToTrash'
                      ? 'bg-[var(--win-subtle-active)] border-[var(--accent)]/40 text-[var(--text-primary)] font-medium'
                      : 'border-transparent text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)]',
                  ].join(' ')}
                >
                  移至废纸篓（可恢复）
                </button>
                <button
                  type="button"
                  onClick={() => setDisposal('permanentlyDelete')}
                  className={[
                    'px-2.5 py-1 rounded-[var(--win-radius-control)] border text-[11.5px] cursor-pointer',
                    disposal === 'permanentlyDelete'
                      ? 'bg-[var(--danger-soft)] border-[var(--danger)]/40 text-[var(--danger)] font-medium'
                      : 'border-transparent text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)]',
                  ].join(' ')}
                >
                  彻底删除并释放空间
                </button>
              </div>
            </div>

            <div className="flex items-center gap-2">
              <Button variant="standard" size="sm" onClick={closeDeduplication}>
                关闭
              </Button>
              <Button
                variant={disposal === 'permanentlyDelete' ? 'danger' : 'accent'}
                size="sm"
                disabled={activePlans.plans.length === 0 || resolving || scanning}
                onClick={() => {
                  if (disposal === 'permanentlyDelete') {
                    setConfirmPermanentOpen(true);
                  } else {
                    void executeCleanup();
                  }
                }}
              >
                {resolving
                  ? '正在清理…'
                  : activePlans.plans.length > 0
                    ? `清理 ${activePlans.plans.length} 组重复项（释放 ${formatBytes(activePlans.reclaimBytes)}）`
                    : '暂无待清理项'}
              </Button>
            </div>
          </div>
        </div>
      </div>

      {/* Centered Irreversible Permanent Delete Confirmation (above z-[115] Dedup modal, below z-[130] Quick Look) */}
      <ModalShell
        open={confirmPermanentOpen}
        onClose={() => setConfirmPermanentOpen(false)}
        title={`彻底删除 ${activePlans.removeCount} 项重复素材？`}
        width="sm"
        zIndexBase={122}
        footer={
          <>
            <Button variant="standard" onClick={() => setConfirmPermanentOpen(false)}>
              取消
            </Button>
            <Button variant="danger" onClick={() => void executeCleanup()}>
              确认彻底删除
            </Button>
          </>
        }
      >
        <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed charkle-prose">
          此操作将永久删除所选 {activePlans.plans.length} 组中的 {activePlans.removeCount}{' '}
          项副本并释放 {formatBytes(activePlans.reclaimBytes)} 磁盘空间，无法从回收站恢复。
          {mergeMetadata ? '各组保留母版将自动继承标签、评分、备注与情绪板引用。' : ''}
        </p>
      </ModalShell>
    </>,
    document.body,
  );
};
