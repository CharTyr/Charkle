import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowDown,
  ArrowDownCircle,
  ArrowDownToLine,
  ArrowUp,
  ArrowUpToLine,
  Camera,
  Check,
  ChevronDown,
  Copy,
  Crop,
  ExternalLink,
  Eye,
  GitFork,
  GripVertical,
  MapPin,
  Palette,
  RefreshCw,
  RotateCcw,
  Sparkles,
  Star,
  Tag,
  Trash2,
  X,
} from 'lucide-react';
import {
  buildFolderPathsMap,
  createDefaultAssetBatchPatch,
  DEFAULT_INSPECTOR_SECTION_ORDER,
  formatPhotoExifAperture,
  formatPhotoExifFocalLength,
  getAssetDisplayTypeLabel,
  getEffectiveSocialAttachments,
  getPhotoExifCameraDisplayName,
  getPhotoExifExposureSummary,
  hasMeaningfulCameraExif,
  inspectorInfoSectionTitle,
  isAIGenerationEmpty,
  moveInspectorSectionToBottom,
  moveInspectorSectionToTop,
  socialPlatformDisplayName,
  stepInspectorSection,
} from '@charkle/shared';
import type { AssetRecord, InspectorInfoSection, ScoredAsset, UUID } from '@charkle/shared';
import { apiClient } from '../../api/client';
import {
  HoverMediaPreview,
  notifyLiveScrolling,
  stopAllHoverPreviews,
} from '../../components/HoverMediaPreview';
import {
  Button,
  CharkleFolderIcon,
  CharkleIcon,
  computeAmbientTintStyle,
  ConfirmDialog,
  DisclosureGroup,
  EmptyStateVignette,
  FolderHierarchyMenu,
  formatBytes,
  getGitHubLanguageColor,
  InspectorSimilarSkeleton,
  Popover,
  prefersReducedMotion,
  SegmentedControl,
  useDelayedFlag,
  usePresence,
  useResolvedIsDark,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';

export interface InspectorViewProps {
  pinnedAsset?: AssetRecord | null;
  isQuickLookHosted?: boolean;
  onRequestCloseQuickLook?: () => void;
}

// Module-level synchronous caches for zero-flicker asset switching & one-shot EXIF/AI hydration
const hydratedAssetCache = new Map<UUID, AssetRecord>();
const hydrationAttemptedIDs = new Set<UUID>();

const INSPECTOR_TAB_OPTIONS = [
  { id: 'info' as const, label: '信息' },
  { id: 'similar' as const, label: '类似项目' },
];

function arraysEqual<T>(a: readonly T[], b: readonly T[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

function formatExposureBias(ev: number): string {
  const rounded = Math.round(ev * 10) / 10;
  if (rounded === 0) return '0 EV';
  return `${rounded > 0 ? '+' : ''}${rounded} EV`;
}

function moveSectionRelative(
  dragged: InspectorInfoSection,
  target: InspectorInfoSection,
  position: 'before' | 'after',
  order: readonly InspectorInfoSection[],
): InspectorInfoSection[] {
  if (dragged === target) return [...order];
  const without = order.filter((s) => s !== dragged);
  const idx = without.indexOf(target);
  if (idx < 0) return [...order];
  const insertIdx = position === 'before' ? idx : idx + 1;
  without.splice(insertIdx, 0, dragged);
  return without;
}

export const InspectorView: React.FC<InspectorViewProps> = ({
  pinnedAsset = null,
  isQuickLookHosted = false,
  onRequestCloseQuickLook,
}) => {
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const selectedInspectorTab = useCoordinatorStore((s) => s.selectedInspectorTab);
  const setSelectedInspectorTab = useCoordinatorStore((s) => s.setSelectedInspectorTab);
  const inspectorSectionOrder = useCoordinatorStore((s) => s.inspectorSectionOrder);
  const setInspectorSectionOrder = useCoordinatorStore((s) => s.setInspectorSectionOrder);
  const resetInspectorSectionOrder = useCoordinatorStore((s) => s.resetInspectorSectionOrder);
  const destination = useCoordinatorStore((s) => s.destination);
  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const openGeneratorModal = useCoordinatorStore((s) => s.openGeneratorModal);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const assets = useLibraryStore((s) => s.assets);
  const assetsByID = useLibraryStore((s) => s.assetsByID);
  const folders = useLibraryStore((s) => s.folders);
  const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);
  const cacheBust = useLibraryStore((s) => s.cacheBustVersion);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const trashAssets = useLibraryStore((s) => s.trashAssets);
  const restoreAssets = useLibraryStore((s) => s.restoreAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);
  const refreshRichAsset = useLibraryStore((s) => s.refreshRichAsset);
  const extractSocialMedia = useLibraryStore((s) => s.extractSocialMedia);
  const setCriteria = useLibraryStore((s) => s.setCriteria);
  const setShowVisualFilterBar = useLibraryStore((s) => s.setShowVisualFilterBar);
  const selectAsset = useLibraryStore((s) => s.selectAsset);
  const upsertAssets = useLibraryStore((s) => s.upsertAssets);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const isDark = useResolvedIsDark();

  const [titleDraft, setTitleDraft] = useState('');
  const [notesDraft, setNotesDraft] = useState('');
  const [tagInput, setTagInput] = useState('');
  const [batchTagInput, setBatchTagInput] = useState('');

  const [similarItems, setSimilarItems] = useState<ScoredAsset[]>([]);
  const [loadingSimilar, setLoadingSimilar] = useState(false);
  const [hoveredSimilarID, setHoveredSimilarID] = useState<UUID | null>(null);
  const [busyAction, setBusyAction] = useState<string | null>(null);

  // Zero-flicker preview image loaded guard (syncs immediately if cached)
  const previewImgRef = useRef<HTMLImageElement | null>(null);
  const [loadedAssetID, setLoadedAssetID] = useState<UUID | null>(null);

  // Drag-reorder state (header-grip only + exponential neighbor displacement ripple)
  const [draggedSection, setDraggedSection] = useState<InspectorInfoSection | null>(null);
  const [dropTarget, setDropTarget] = useState<{
    section: InspectorInfoSection;
    position: 'before' | 'after';
  } | null>(null);

  // Confirmed permanent delete dialog state
  const [confirmDelete, setConfirmDelete] = useState<{
    ids: UUID[];
    title: string;
    closeQuickLookAfter?: boolean;
  } | null>(null);

  // Mounted-exit drawer presence (prevents outer w-0 from clipping inner exit slide)
  const drawerPresence = usePresence(inspectorOpen, 230);

  // Collapsible raw AI parameters
  const [rawParamsOpen, setRawParamsOpen] = useState(false);

  // Folder hierarchy popover triggers
  const [singleFolderMenuOpen, setSingleFolderMenuOpen] = useState(false);
  const singleFolderBtnRef = useRef<HTMLButtonElement | null>(null);
  const [batchFolderMenuOpen, setBatchFolderMenuOpen] = useState(false);
  const batchFolderBtnRef = useRef<HTMLButtonElement | null>(null);

  const showSimilarSkeleton = useDelayedFlag(loadingSimilar, 300, 500);

  const folderPaths = useMemo(() => buildFolderPathsMap(folders), [folders]);
  const foldersByID = useMemo(() => new Map(folders.map((f) => [f.id, f])), [folders]);

  const selectedAssets: AssetRecord[] = useMemo(() => {
    if (isQuickLookHosted) {
      if (!pinnedAsset) return [];
      const live =
        assetsByID[pinnedAsset.id] ?? hydratedAssetCache.get(pinnedAsset.id) ?? pinnedAsset;
      return [live];
    }
    const result: AssetRecord[] = [];
    for (const id of selectedAssetIDs) {
      const found =
        assetsByID[id] ?? hydratedAssetCache.get(id) ?? assets.find((a) => a.id === id);
      if (found) result.push(found);
    }
    return result;
  }, [isQuickLookHosted, pinnedAsset, selectedAssetIDs, assetsByID, assets]);

  const singleAsset = selectedAssets.length === 1 ? selectedAssets[0] : null;
  const activeBoard = boards.find((b) => b.id === activeBoardID) ?? boards[0] ?? null;

  // Keep synchronous module cache fresh whenever singleAsset updates
  useEffect(() => {
    if (singleAsset) {
      hydratedAssetCache.set(singleAsset.id, singleAsset);
    }
  }, [singleAsset]);

  // Sync draft inputs when active asset changes
  useEffect(() => {
    if (!singleAsset) return;
    setTitleDraft(singleAsset.title);
    setNotesDraft(singleAsset.notes);
    setRawParamsOpen(false);
  }, [singleAsset?.id, singleAsset?.title, singleAsset?.notes]);

  // Synchronously detect already-cached preview images before paint to avoid blank flash
  useLayoutEffect(() => {
    if (!singleAsset) return;
    const img = previewImgRef.current;
    if (img && img.complete && img.naturalWidth > 0) {
      setLoadedAssetID(singleAsset.id);
    }
  }, [singleAsset?.id, cacheBust]);

  // On-demand EXIF / AI metadata hydration (one-shot per asset per session)
  useEffect(() => {
    if (!singleAsset) return;
    const eligible =
      singleAsset.mediaKind === 'image' ||
      singleAsset.mediaKind === 'animatedImage' ||
      singleAsset.mediaKind === 'designFile';
    if (!eligible) return;

    const hasExif = Boolean(singleAsset.richMetadata?.photoExif);
    const hasAI = Boolean(singleAsset.richMetadata?.aiGeneration);
    if (hasExif || hasAI) return;
    if (hydrationAttemptedIDs.has(singleAsset.id)) return;

    hydrationAttemptedIDs.add(singleAsset.id);
    let cancelled = false;
    apiClient
      .hydrateAssetMetadata(singleAsset.id)
      .then((res) => {
        if (cancelled || !res.asset) return;
        hydratedAssetCache.set(res.asset.id, res.asset);
        upsertAssets([res.asset]);
      })
      .catch(() => {
        // Non-fatal lazy hydration
      });

    return () => {
      cancelled = true;
    };
  }, [singleAsset?.id, singleAsset?.mediaKind, singleAsset?.richMetadata, upsertAssets]);

  // Fetch similar assets when Similar tab is active
  useEffect(() => {
    if (!singleAsset || selectedInspectorTab !== 'similar') return;
    let cancelled = false;
    setLoadingSimilar(true);
    apiClient
      .getSimilarAssets(singleAsset.id, 12)
      .then((res) => {
        if (!cancelled) {
          setSimilarItems(res.items);
          setLoadingSimilar(false);
        }
      })
      .catch(() => {
        if (!cancelled) setLoadingSimilar(false);
      });
    return () => {
      cancelled = true;
    };
  }, [singleAsset?.id, selectedInspectorTab]);

  const commitTitle = async () => {
    if (!singleAsset) return;
    const trimmed = titleDraft.trim();
    if (!trimmed || trimmed === singleAsset.title) {
      setTitleDraft(singleAsset.title);
      return;
    }
    await batchPatch(createDefaultAssetBatchPatch([singleAsset.id], { title: trimmed }));
  };

  const commitNotes = async () => {
    if (!singleAsset) return;
    if (notesDraft === singleAsset.notes) return;
    await batchPatch(createDefaultAssetBatchPatch([singleAsset.id], { notes: notesDraft }));
  };

  const handleCopyText = async (text: string, label?: string) => {
    try {
      await navigator.clipboard.writeText(text);
      pushToast({ tone: 'info', message: label ? `已复制${label}` : `已复制 ${text}` });
    } catch {
      pushToast({ tone: 'info', message: text.slice(0, 60) });
    }
  };

  const handleFilterByColor = (hex: string) => {
    setShowVisualFilterBar(true);
    setCriteria({ selectedColorHex: hex });
    pushToast({ tone: 'info', message: `已按色值 ${hex} 反向检索素材库` });
    if (isQuickLookHosted) {
      onRequestCloseQuickLook?.();
    }
  };

  const handleAddTag = async (ids: UUID[], raw: string, clearFn: () => void) => {
    const cleaned = raw.trim().replace(/^#+/, '');
    if (!cleaned) return;
    clearFn();
    await batchPatch(createDefaultAssetBatchPatch(ids, { addTags: [cleaned] }));
  };

  const handleAnalyzeAI = async (ids: UUID[]) => {
    setBusyAction('ai-analyze');
    try {
      const res = await apiClient.analyzeAssets({ ids });
      upsertAssets(res.assets);
      pushToast({ tone: 'success', message: `已完成 ${res.assets.length} 项素材 AI 分析与标签建议` });
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : 'AI 分析失败' });
    } finally {
      setBusyAction(null);
    }
  };

  const handleSubjectPalette = async (asset: AssetRecord) => {
    setBusyAction('subject-palette');
    try {
      const res = await apiClient.extractSubjectPalette({ assetID: asset.id });
      upsertAssets([res.result.updatedAsset]);
      pushToast({
        tone: 'success',
        message: `已按主体区域重新提取 ${res.result.colors.length} 个主色`,
      });
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '主体色板提取失败' });
    } finally {
      setBusyAction(null);
    }
  };

  const handleCleanBounds = async (asset: AssetRecord) => {
    setBusyAction('clean-bounds');
    try {
      const res = await apiClient.detectCleanBounds(asset.id);
      pushToast({
        tone: 'info',
        message: res.result.hasNoise
          ? `检测到杂边/水印区域：${res.result.summary}`
          : `画面边缘干净：${res.result.summary}`,
      });
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '自动去杂边检测失败' });
    } finally {
      setBusyAction(null);
    }
  };

  const visibleSections = useMemo<InspectorInfoSection[]>(() => {
    if (!singleAsset) return [];
    const exif = singleAsset.richMetadata?.photoExif;
    const aiGen = singleAsset.richMetadata?.aiGeneration;
    return inspectorSectionOrder.filter((section) => {
      switch (section) {
        case 'aiGeneration':
          return !isAIGenerationEmpty(aiGen);
        case 'photoExif':
          return hasMeaningfulCameraExif(exif);
        case 'githubRepo':
          return Boolean(singleAsset.richMetadata?.githubRepo);
        case 'socialMediaExtract':
          return Boolean(singleAsset.richMetadata?.socialPost);
        default:
          return true;
      }
    });
  }, [singleAsset, inspectorSectionOrder]);

  const isCustomSectionOrder = !arraysEqual(inspectorSectionOrder, DEFAULT_INSPECTOR_SECTION_ORDER);

  // Moodboard workspace has its own Candidate Pool panel (except when hosted inside Quick Look!)
  if (!isQuickLookHosted && destination.type === 'moodboard') return null;
  if (!drawerPresence.rendered && !confirmDelete) return null;

  const draggedVisIdx = draggedSection ? visibleSections.indexOf(draggedSection) : -1;
  const targetVisIdx = dropTarget ? visibleSections.indexOf(dropTarget.section) : -1;
  let activeGapIndex = -1;
  if (draggedVisIdx >= 0 && targetVisIdx >= 0 && draggedVisIdx !== targetVisIdx && dropTarget) {
    const rawGap = dropTarget.position === 'before' ? targetVisIdx : targetVisIdx + 1;
    if (rawGap !== draggedVisIdx && rawGap !== draggedVisIdx + 1) {
      activeGapIndex = rawGap;
    }
  }
  const reducedMotion = prefersReducedMotion();

  const renderSectionCard = (section: InspectorInfoSection, visIndex: number) => {
    if (!singleAsset) return null;
    const isFirst = visIndex === 0;
    const isLast = visIndex === visibleSections.length - 1;
    const isDragging = draggedSection === section;

    // Drag-to-reorder neighbor ripple: exponential A * 0.7^n decay away from active insertion gap
    let rippleOffsetY = 0;
    let rippleDelayMs = 0;
    if (activeGapIndex >= 0 && visIndex !== draggedVisIdx && !reducedMotion) {
      const isAboveGap = visIndex < activeGapIndex;
      const distance = isAboveGap ? activeGapIndex - 1 - visIndex : visIndex - activeGapIndex;
      const sign = isAboveGap ? -1 : 1;
      rippleOffsetY = sign * 8 * Math.pow(0.7, distance);
      rippleDelayMs = distance * 24;
    }
    const showLineBefore = activeGapIndex === visIndex;
    const showLineAfter =
      activeGapIndex === visibleSections.length && visIndex === visibleSections.length - 1;

    let body: React.ReactNode = null;

    switch (section) {
      case 'previewIdentity': {
        const previewSrc = apiClient.thumbnailURL(
          singleAsset.id,
          'grid520',
          `${singleAsset.updatedAt}-${cacheBust}`,
        );
        const imageReady = loadedAssetID === singleAsset.id;

        body = (
          <div className="flex flex-col gap-2.5">
            {!isQuickLookHosted && (
              <div
                onClick={(e) =>
                  openQuickLook(singleAsset.id, e.currentTarget.getBoundingClientRect())
                }
                className="group/preview relative aspect-[16/10] w-full overflow-hidden rounded-[var(--radius-card-outer)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] cursor-zoom-in"
              >
                <img
                  ref={previewImgRef}
                  key={singleAsset.id}
                  src={previewSrc}
                  alt={singleAsset.title}
                  onLoad={() => setLoadedAssetID(singleAsset.id)}
                  onError={() => setLoadedAssetID(singleAsset.id)}
                  className={[
                    'w-full h-full object-contain bg-black/5 transition-opacity duration-[140ms] ease-[var(--ease-out)]',
                    imageReady ? 'opacity-100' : 'opacity-0',
                  ].join(' ')}
                />
                <span className="absolute bottom-2 right-2 px-2 py-0.5 rounded-[var(--radius-card-inner)] bg-black/60 text-white text-[11px] inline-flex items-center gap-1 opacity-0 group-hover/preview:opacity-100 transition-opacity duration-[150ms] ease-[var(--ease-out)]">
                  <Eye size={11} />
                  Space 预览
                </span>
              </div>
            )}

            {/* Inline Title */}
            <input
              type="text"
              aria-label="素材标题"
              value={titleDraft}
              onChange={(e) => setTitleDraft(e.target.value)}
              onBlur={() => void commitTitle()}
              onKeyDown={(e) => {
                if (e.key === 'Enter') (e.target as HTMLInputElement).blur();
              }}
              className="w-full px-2 py-1 text-[13.5px] font-semibold rounded-[var(--radius-chip)] bg-transparent hover:bg-[var(--bg-inspector-field)] focus:bg-[var(--bg-elevated)] border border-transparent focus:border-[var(--accent)] text-[var(--text-primary)] focus:outline-none"
            />

            {/* Star Rating + Pin Offline */}
            <div className="flex items-center justify-between gap-2 px-1">
              <div className="flex items-center gap-0.5">
                {[1, 2, 3, 4, 5].map((star) => (
                  <button
                    key={star}
                    type="button"
                    aria-label={`评分 ${star} 星`}
                    onClick={() =>
                      void batchPatch(
                        createDefaultAssetBatchPatch([singleAsset.id], {
                          rating: singleAsset.rating === star ? 0 : star,
                        }),
                      )
                    }
                    className="charkle-pressable p-0.5 cursor-pointer"
                  >
                    <Star
                      size={15}
                      className={
                        singleAsset.rating >= star
                          ? 'fill-[#F2C14E] text-[#F2C14E] charkle-micro-pop'
                          : 'text-[var(--text-tertiary)]'
                      }
                    />
                  </button>
                ))}
              </div>

              <button
                type="button"
                onClick={() =>
                  void batchPatch(
                    createDefaultAssetBatchPatch([singleAsset.id], {
                      pinnedOffline: !singleAsset.pinnedOffline,
                    }),
                  )
                }
                className={[
                  'charkle-pressable inline-flex items-center gap-1 px-2 py-1 rounded-[var(--radius-chip)] text-[11.5px] font-medium cursor-pointer',
                  singleAsset.pinnedOffline
                    ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                    : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                ].join(' ')}
              >
                <ArrowDownCircle size={12} />
                {singleAsset.pinnedOffline ? '已离线保留' : '保留离线'}
              </button>
            </div>
          </div>
        );
        break;
      }

      case 'quickActions': {
        const assignedFolder = singleAsset.folderID
          ? foldersByID.get(singleAsset.folderID) ?? null
          : null;
        const folderLabel = assignedFolder
          ? folderPaths[assignedFolder.id] || assignedFolder.name
          : '收件箱';

        body = (
          <div className="flex flex-col gap-2">
            <div className="flex items-center gap-2">
              <span className="text-[11.5px] text-[var(--text-secondary)] shrink-0">位置</span>
              <button
                ref={singleFolderBtnRef}
                type="button"
                aria-haspopup="menu"
                aria-expanded={singleFolderMenuOpen}
                onClick={() => setSingleFolderMenuOpen((v) => !v)}
                className="charkle-pressable flex-1 min-w-0 min-h-[28px] px-2 py-1 text-[12px] rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] hover:bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[var(--text-primary)] inline-flex items-center gap-1.5 cursor-pointer text-left"
              >
                {assignedFolder ? (
                  <CharkleFolderIcon
                    colorHex={assignedFolder.colorHex}
                    customSymbol={assignedFolder.customSymbol}
                    size={14}
                  />
                ) : (
                  <CharkleIcon name="inbox" size={14} />
                )}
                <span className="truncate flex-1">{folderLabel}</span>
                <ChevronDown size={12} className="text-[var(--text-tertiary)] shrink-0" />
              </button>
            </div>

            <Popover
              open={singleFolderMenuOpen}
              onOpenChange={setSingleFolderMenuOpen}
              anchorEl={singleFolderBtnRef.current}
              placement="bottom-end"
            >
              <FolderHierarchyMenu
                folders={folders}
                includeInbox
                selectedFolderID={singleAsset.folderID ?? null}
                highlightSelection
                parentSelfPrefix="放入"
                submenuSide="left"
                onSelectFolder={(folderID) => {
                  setSingleFolderMenuOpen(false);
                  void batchPatch(
                    createDefaultAssetBatchPatch([singleAsset.id], {
                      folderAssignment: folderID
                        ? { type: 'folder', folderID }
                        : { type: 'inbox' },
                    }),
                  );
                }}
              />
            </Popover>

            <div className="flex items-center gap-1.5">
              <Button
                variant="secondary"
                size="xs"
                className="flex-1 justify-center"
                onClick={async () => {
                  if (!activeBoard) {
                    openGeneratorModal([singleAsset.id]);
                    return;
                  }
                  await addAssetsToBoard(activeBoard.id, [singleAsset.id]);
                  pushToast({
                    tone: 'success',
                    message: `已加入情绪板「${activeBoard.title}」`,
                  });
                }}
              >
                <CharkleIcon name="moodboard" size={14} />
                加入情绪板
              </Button>

              {singleAsset.isTrashed ? (
                <>
                  <Button
                    variant="secondary"
                    size="xs"
                    onClick={() => void restoreAssets([singleAsset.id])}
                  >
                    <RotateCcw size={12} />
                    恢复
                  </Button>
                  <Button
                    variant="danger"
                    size="xs"
                    title="彻底删除"
                    onClick={() =>
                      setConfirmDelete({
                        ids: [singleAsset.id],
                        title: `彻底删除「${singleAsset.title}」？`,
                        closeQuickLookAfter: isQuickLookHosted,
                      })
                    }
                  >
                    <Trash2 size={12} />
                  </Button>
                </>
              ) : (
                <Button
                  variant="ghost"
                  size="xs"
                  onClick={() => {
                    void trashAssets([singleAsset.id]);
                    if (isQuickLookHosted) onRequestCloseQuickLook?.();
                  }}
                  title="移入回收站"
                >
                  <Trash2 size={13} className="text-[var(--danger)]" />
                </Button>
              )}
            </div>
          </div>
        );
        break;
      }

      case 'colorsAndTags': {
        body = (
          <div className="flex flex-col gap-3">
            {/* Palette */}
            <div className="flex flex-col gap-2">
              <div className="flex items-center justify-between">
                <span className="text-[11px] font-medium text-[var(--text-tertiary)]">主色板</span>
              </div>

              {singleAsset.dominantColors.length > 0 ? (
                <div className="flex items-center gap-1.5">
                  {singleAsset.dominantColors.slice(0, 6).map((swatch) => (
                    <button
                      key={swatch.hex}
                      type="button"
                      title={`${swatch.hex}（左键复制 / 右键按色检索）`}
                      onClick={() => void handleCopyText(swatch.hex, `色值 ${swatch.hex}`)}
                      onContextMenu={(e) => {
                        e.preventDefault();
                        handleFilterByColor(swatch.hex);
                      }}
                      className="charkle-pressable flex-1 h-7 rounded-[6px] border border-black/10 cursor-pointer relative"
                      style={{ backgroundColor: swatch.hex }}
                    >
                      <span className="sr-only">{swatch.hex}</span>
                    </button>
                  ))}
                </div>
              ) : (
                <div className="text-[11.5px] text-[var(--text-tertiary)]">暂无主色数据</div>
              )}

              {(singleAsset.mediaKind === 'image' ||
                singleAsset.mediaKind === 'animatedImage' ||
                singleAsset.mediaKind === 'designFile') && (
                <div className="flex items-center gap-1.5">
                  <Button
                    variant="ghost"
                    size="xs"
                    loading={busyAction === 'subject-palette'}
                    onClick={() => void handleSubjectPalette(singleAsset)}
                    className="flex-1 justify-center bg-[var(--bg-subtle)]/70"
                  >
                    <Palette size={12} />
                    按主体重提
                  </Button>
                  <Button
                    variant="ghost"
                    size="xs"
                    loading={busyAction === 'clean-bounds'}
                    onClick={() => void handleCleanBounds(singleAsset)}
                    className="flex-1 justify-center bg-[var(--bg-subtle)]/70"
                  >
                    <Crop size={12} />
                    自动去杂边
                  </Button>
                </div>
              )}
            </div>

            <div className="border-t border-[var(--border-hairline)]" />

            {/* Tags + AI Suggested Tags */}
            <div className="flex flex-col gap-2">
              <div className="flex items-center justify-between">
                <span className="text-[11px] font-medium text-[var(--text-tertiary)]">标签</span>
                <button
                  type="button"
                  disabled={busyAction === 'ai-analyze'}
                  onClick={() => void handleAnalyzeAI([singleAsset.id])}
                  className="charkle-pressable inline-flex items-center gap-1 text-[11px] font-medium text-[var(--accent)] hover:underline cursor-pointer disabled:opacity-50"
                >
                  <Sparkles size={11} />
                  {busyAction === 'ai-analyze' ? '分析中…' : 'AI 建议标签'}
                </button>
              </div>

              {singleAsset.tags.length > 0 && (
                <div className="flex flex-wrap gap-1">
                  {singleAsset.tags.map((tag) => (
                    <span
                      key={tag}
                      className="inline-flex items-center gap-1 px-2 py-0.5 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[11.5px] text-[var(--text-primary)]"
                    >
                      #{tag}
                      <button
                        type="button"
                        aria-label={`移除标签 ${tag}`}
                        onClick={() =>
                          void batchPatch(
                            createDefaultAssetBatchPatch([singleAsset.id], { removeTags: [tag] }),
                          )
                        }
                        className="text-[var(--text-tertiary)] hover:text-[var(--danger)] cursor-pointer"
                      >
                        <X size={10} />
                      </button>
                    </span>
                  ))}
                </div>
              )}

              <input
                type="text"
                value={tagInput}
                onChange={(e) => setTagInput(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault();
                    void handleAddTag([singleAsset.id], tagInput, () => setTagInput(''));
                  }
                }}
                placeholder="添加标签，回车确认…"
                className="min-h-[30px] px-2.5 text-[12px] rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
              />

              {singleAsset.suggestedTags.length > 0 && (
                <div className="pt-1.5 border-t border-[var(--border-hairline)] flex flex-col gap-1.5">
                  <div className="flex items-center justify-between text-[11px]">
                    <span className="text-[var(--text-tertiary)]">AI 推荐标签</span>
                    <button
                      type="button"
                      onClick={() =>
                        void batchPatch(
                          createDefaultAssetBatchPatch([singleAsset.id], {
                            acceptSuggestedTags: true,
                          }),
                        )
                      }
                      className="text-[var(--accent)] hover:underline cursor-pointer"
                    >
                      全部采纳
                    </button>
                  </div>
                  <div className="flex flex-wrap gap-1">
                    {singleAsset.suggestedTags.map((sug) => (
                      <span
                        key={sug}
                        className="inline-flex items-center gap-1 pl-2 pr-1 py-0.5 rounded-[var(--radius-chip)] bg-[var(--accent-soft)] text-[var(--accent)] text-[11.5px]"
                      >
                        <button
                          type="button"
                          onClick={() =>
                            void batchPatch(
                              createDefaultAssetBatchPatch([singleAsset.id], {
                                addTags: [sug],
                                dismissSuggestedTags: [sug],
                              }),
                            )
                          }
                          className="inline-flex items-center gap-0.5 cursor-pointer"
                          title="采纳标签"
                        >
                          <Check size={10} />
                          {sug}
                        </button>
                        <button
                          type="button"
                          onClick={() =>
                            void batchPatch(
                              createDefaultAssetBatchPatch([singleAsset.id], {
                                dismissSuggestedTags: [sug],
                              }),
                            )
                          }
                          className="p-0.5 opacity-65 hover:opacity-100 cursor-pointer"
                          title="忽略"
                        >
                          <X size={10} />
                        </button>
                      </span>
                    ))}
                  </div>
                </div>
              )}
            </div>
          </div>
        );
        break;
      }

      case 'notesAndOCR': {
        body = (
          <div className="flex flex-col gap-2.5">
            <textarea
              rows={3}
              aria-label="素材备注"
              value={notesDraft}
              onChange={(e) => setNotesDraft(e.target.value)}
              onBlur={() => void commitNotes()}
              placeholder="添加备注…"
              className="w-full p-2.5 text-[12px] leading-relaxed rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)] resize-y"
            />

            {singleAsset.aiDescription && (
              <div className="p-2 rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)]">
                <div className="text-[10.5px] font-semibold text-[var(--text-tertiary)] mb-1">
                  AI 视觉描述
                </div>
                <p className="text-[11.5px] text-[var(--text-secondary)] leading-relaxed charkle-wrap-anywhere">
                  {singleAsset.aiDescription}
                </p>
              </div>
            )}

            {singleAsset.ocrText && (
              <div className="p-2 rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)]">
                <div className="flex items-center justify-between mb-1">
                  <span className="text-[10.5px] font-semibold text-[var(--text-tertiary)]">
                    画面识别文本
                  </span>
                  <button
                    type="button"
                    onClick={() => void handleCopyText(singleAsset.ocrText!, '识别文本')}
                    className="text-[10.5px] text-[var(--accent)] hover:underline inline-flex items-center gap-0.5 cursor-pointer"
                  >
                    <Copy size={10} />
                    复制
                  </button>
                </div>
                <p className="text-[11.5px] text-[var(--text-secondary)] leading-relaxed whitespace-pre-wrap max-h-[120px] overflow-y-auto charkle-scroll charkle-wrap-anywhere">
                  {singleAsset.ocrText}
                </p>
              </div>
            )}
          </div>
        );
        break;
      }

      case 'aiGeneration': {
        const ai = singleAsset.richMetadata?.aiGeneration;
        if (!ai || isAIGenerationEmpty(ai)) return null;

        const paramRows: Array<{ label: string; value: string }> = [];
        if (ai.modelName) paramRows.push({ label: '模型', value: ai.modelName });
        if (ai.sampler) paramRows.push({ label: '采样器', value: ai.sampler });
        if (ai.scheduler) paramRows.push({ label: '调度器', value: ai.scheduler });
        if (ai.steps != null) paramRows.push({ label: '步数', value: String(ai.steps) });
        if (ai.cfgScale != null) paramRows.push({ label: 'CFG', value: String(ai.cfgScale) });
        if (ai.seed) paramRows.push({ label: '种子', value: ai.seed });
        if (ai.sizeText) paramRows.push({ label: '生成尺寸', value: ai.sizeText });
        if (ai.clipSkip != null) paramRows.push({ label: 'Clip Skip', value: String(ai.clipSkip) });
        if (ai.modelHash) paramRows.push({ label: '模型哈希', value: ai.modelHash });
        for (const [k, v] of Object.entries(ai.extraParameters ?? {}).slice(0, 6)) {
          if (v) paramRows.push({ label: k, value: v });
        }

        body = (
          <div className="flex flex-col gap-2.5">
            {ai.generator && (
              <div className="flex items-center justify-between gap-2">
                <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-[var(--radius-chip)] bg-[var(--accent-soft)] text-[var(--accent)] text-[11px] font-semibold">
                  <Sparkles size={10.5} />
                  {ai.generator}
                </span>
              </div>
            )}

            {ai.prompt && (
              <div className="flex flex-col gap-1">
                <div className="flex items-center justify-between">
                  <span className="text-[11px] font-medium text-[var(--text-tertiary)]">
                    正向提示词
                  </span>
                  <button
                    type="button"
                    onClick={() => void handleCopyText(ai.prompt!, '正向提示词')}
                    className="charkle-pressable inline-flex items-center gap-1 px-1.5 py-0.5 rounded-[5px] text-[10.5px] font-medium text-[var(--accent)] hover:bg-[var(--accent-soft)] cursor-pointer"
                  >
                    <Copy size={10} />
                    复制
                  </button>
                </div>
                <div className="p-2 rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[11.5px] leading-relaxed text-[var(--text-primary)] max-h-[140px] overflow-y-auto charkle-scroll select-text charkle-wrap-anywhere">
                  {ai.prompt}
                </div>
              </div>
            )}

            {ai.negativePrompt && (
              <div className="flex flex-col gap-1">
                <div className="flex items-center justify-between">
                  <span className="text-[11px] font-medium text-[var(--text-tertiary)]">
                    负向提示词
                  </span>
                  <button
                    type="button"
                    onClick={() => void handleCopyText(ai.negativePrompt!, '负向提示词')}
                    className="charkle-pressable inline-flex items-center gap-1 px-1.5 py-0.5 rounded-[5px] text-[10.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
                  >
                    <Copy size={10} />
                    复制
                  </button>
                </div>
                <div className="p-2 rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[11.5px] leading-relaxed text-[var(--text-secondary)] max-h-[100px] overflow-y-auto charkle-scroll select-text charkle-wrap-anywhere">
                  {ai.negativePrompt}
                </div>
              </div>
            )}

            {paramRows.length > 0 && (
              <div className="grid grid-cols-2 gap-x-2.5 gap-y-1.5 text-[11px]">
                {paramRows.map((row) => (
                  <div key={row.label} className="min-w-0">
                    <div className="text-[10px] text-[var(--text-tertiary)] truncate">
                      {row.label}
                    </div>
                    <div
                      title={row.value}
                      className="text-[var(--text-primary)] font-mono tabular-nums truncate"
                    >
                      {row.value}
                    </div>
                  </div>
                ))}
              </div>
            )}

            {ai.loras.length > 0 && (
              <div className="flex flex-col gap-1">
                <span className="text-[10.5px] font-medium text-[var(--text-tertiary)]">LoRA</span>
                <div className="flex flex-wrap gap-1">
                  {ai.loras.map((lora, idx) => (
                    <span
                      key={`${lora}-${idx}`}
                      className="px-1.5 py-0.5 rounded-[6px] bg-[var(--bg-subtle)] text-[10.5px] font-mono text-[var(--text-primary)] max-w-full truncate"
                    >
                      {lora}
                    </span>
                  ))}
                </div>
              </div>
            )}

            {ai.rawParameters && (
              <DisclosureGroup
                open={rawParamsOpen}
                onOpenChange={setRawParamsOpen}
                headerClassName="px-1.5 min-h-[26px]"
                label={
                  <span className="text-[11px] font-medium text-[var(--text-secondary)]">
                    完整原始生成参数
                  </span>
                }
              >
                <div className="flex flex-col gap-1.5">
                  <pre className="p-2 rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[10.5px] font-mono text-[var(--text-secondary)] max-h-[150px] overflow-auto charkle-scroll whitespace-pre-wrap charkle-wrap-anywhere select-text">
                    {ai.rawParameters}
                  </pre>
                  <button
                    type="button"
                    onClick={() => void handleCopyText(ai.rawParameters!, '完整生成参数')}
                    className="self-end inline-flex items-center gap-1 text-[11px] text-[var(--accent)] hover:underline cursor-pointer"
                  >
                    <Copy size={10.5} />
                    复制全部参数
                  </button>
                </div>
              </DisclosureGroup>
            )}
          </div>
        );
        break;
      }

      case 'photoExif': {
        const exif = singleAsset.richMetadata?.photoExif;
        if (!exif || !hasMeaningfulCameraExif(exif)) return null;

        const cameraName = getPhotoExifCameraDisplayName(exif);
        const exposureSummary = getPhotoExifExposureSummary(exif);
        const focalLengthText = formatPhotoExifFocalLength(exif);
        const apertureText = formatPhotoExifAperture(exif);
        const hasGps = exif.latitude != null && exif.longitude != null;
        const gpsText = hasGps
          ? `${exif.latitude!.toFixed(5)}, ${exif.longitude!.toFixed(5)}${
              exif.altitudeMeters != null ? ` (${Math.round(exif.altitudeMeters)}m)` : ''
            }`
          : null;

        const exifRows: Array<{ label: string; value: string }> = [];
        if (focalLengthText) exifRows.push({ label: '焦距', value: focalLengthText });
        if (apertureText) exifRows.push({ label: '光圈', value: apertureText });
        if (exif.exposureTime) exifRows.push({ label: '快门', value: exif.exposureTime });
        if (exif.iso != null) exifRows.push({ label: 'ISO', value: String(exif.iso) });
        if (exif.exposureBiasEV != null) {
          exifRows.push({ label: '曝光补偿', value: formatExposureBias(exif.exposureBiasEV) });
        }
        if (exif.meteringMode) exifRows.push({ label: '测光模式', value: exif.meteringMode });
        if (exif.flashFired != null) {
          exifRows.push({ label: '闪光灯', value: exif.flashFired ? '已触发' : '未触发' });
        }
        if (exif.whiteBalance) exifRows.push({ label: '白平衡', value: exif.whiteBalance });
        if (exif.capturedAt) exifRows.push({ label: '拍摄时间', value: exif.capturedAt });
        if (exif.software) exifRows.push({ label: '后期软件', value: exif.software });
        if (exif.artist) exifRows.push({ label: '作者', value: exif.artist });
        if (exif.copyright) exifRows.push({ label: '版权', value: exif.copyright });

        body = (
          <div className="flex flex-col gap-2">
            {(cameraName || exif.lensModel) && (
              <div className="flex items-start gap-2">
                <Camera size={13.5} className="text-[var(--text-tertiary)] shrink-0 mt-0.5" />
                <div className="min-w-0 flex-1">
                  {cameraName && (
                    <div className="text-[12px] font-semibold text-[var(--text-primary)] truncate">
                      {cameraName}
                    </div>
                  )}
                  {exif.lensModel && (
                    <div className="text-[11px] text-[var(--text-secondary)] truncate">
                      {exif.lensModel}
                    </div>
                  )}
                </div>
              </div>
            )}

            {exposureSummary && (
              <div className="px-2.5 py-1.5 rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[11.5px] font-mono tabular-nums text-[var(--text-primary)] truncate">
                {exposureSummary}
              </div>
            )}

            {exifRows.length > 0 && (
              <div className="grid grid-cols-2 gap-x-2.5 gap-y-1.5 text-[11px]">
                {exifRows.map((row) => (
                  <div
                    key={row.label}
                    className={
                      row.label === '拍摄时间' || row.label === '后期软件' || row.label === '版权'
                        ? 'col-span-2 min-w-0'
                        : 'min-w-0'
                    }
                  >
                    <div className="text-[10px] text-[var(--text-tertiary)]">{row.label}</div>
                    <div
                      title={row.value}
                      className="text-[var(--text-primary)] tabular-nums truncate"
                    >
                      {row.value}
                    </div>
                  </div>
                ))}
              </div>
            )}

            {gpsText && (
              <div className="pt-1.5 border-t border-[var(--border-hairline)] flex items-center justify-between gap-2 text-[11px]">
                <span className="inline-flex items-center gap-1 text-[var(--text-secondary)] font-mono tabular-nums truncate">
                  <MapPin size={11} className="text-[var(--accent)] shrink-0" />
                  {gpsText}
                </span>
                <button
                  type="button"
                  onClick={() => void handleCopyText(gpsText, '拍摄坐标')}
                  className="text-[var(--accent)] hover:underline shrink-0 cursor-pointer"
                >
                  复制坐标
                </button>
              </div>
            )}
          </div>
        );
        break;
      }

      case 'mediaSpecs': {
        const exif = singleAsset.richMetadata?.photoExif;
        body = (
          <div className="grid grid-cols-2 gap-x-3 gap-y-2 text-[11.5px]">
            <div>
              <div className="text-[10.5px] text-[var(--text-tertiary)]">类型</div>
              <div className="text-[var(--text-primary)] font-medium truncate">
                {getAssetDisplayTypeLabel(singleAsset)}
              </div>
            </div>
            <div>
              <div className="text-[10.5px] text-[var(--text-tertiary)]">尺寸</div>
              <div className="text-[var(--text-primary)] font-mono tabular-nums">
                {singleAsset.pixelWidth > 0
                  ? `${singleAsset.pixelWidth}×${singleAsset.pixelHeight}`
                  : '—'}
              </div>
            </div>
            <div>
              <div className="text-[10.5px] text-[var(--text-tertiary)]">大小</div>
              <div className="text-[var(--text-primary)] font-mono tabular-nums">
                {formatBytes(singleAsset.fileSizeBytes)}
              </div>
            </div>
            <div>
              <div className="text-[10.5px] text-[var(--text-tertiary)]">添加时间</div>
              <div className="text-[var(--text-primary)] tabular-nums">
                {new Date(singleAsset.createdAt).toLocaleDateString('zh-CN')}
              </div>
            </div>
            {exif?.colorProfile && (
              <div>
                <div className="text-[10.5px] text-[var(--text-tertiary)]">色彩描述文件</div>
                <div className="text-[var(--text-primary)] truncate">{exif.colorProfile}</div>
              </div>
            )}
            {(exif?.bitDepth != null || exif?.dpiWidth != null) && (
              <div>
                <div className="text-[10.5px] text-[var(--text-tertiary)]">位深 / DPI</div>
                <div className="text-[var(--text-primary)] font-mono tabular-nums">
                  {[
                    exif.bitDepth != null ? `${exif.bitDepth}-bit` : null,
                    exif.dpiWidth != null ? `${Math.round(exif.dpiWidth)} DPI` : null,
                  ]
                    .filter(Boolean)
                    .join(' · ')}
                </div>
              </div>
            )}
            {singleAsset.sourceURL && (
              <div className="col-span-2 min-w-0">
                <div className="text-[10.5px] text-[var(--text-tertiary)]">来源链接</div>
                <a
                  href={singleAsset.sourceURL}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-[var(--accent)] hover:underline truncate block"
                >
                  {singleAsset.sourceDomain || singleAsset.sourceURL}
                </a>
              </div>
            )}
          </div>
        );
        break;
      }

      case 'githubRepo': {
        const repo = singleAsset.richMetadata?.githubRepo;
        if (!repo) return null;
        body = (
          <div className="flex flex-col gap-2 p-2.5 -m-1 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] text-[var(--text-primary)] border border-[var(--border-hairline)]">
            <div className="flex items-center justify-between gap-2">
              <span className="text-[12px] font-semibold truncate">{repo.fullName}</span>
              <button
                type="button"
                title="刷新仓库信息"
                onClick={async () => {
                  setBusyAction('refresh-rich');
                  try {
                    await refreshRichAsset(singleAsset.id);
                    pushToast({ tone: 'success', message: '已刷新仓库信息' });
                  } finally {
                    setBusyAction(null);
                  }
                }}
                className="p-1 rounded text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
              >
                <RefreshCw
                  size={12}
                  className={busyAction === 'refresh-rich' ? 'animate-spin' : ''}
                />
              </button>
            </div>
            <div className="flex items-center gap-3 text-[11px] text-[var(--text-secondary)] tabular-nums">
              <span className="inline-flex items-center gap-1">
                <Star size={11} className="text-[#F2C14E]" />
                {repo.stars.toLocaleString()}
              </span>
              <span className="inline-flex items-center gap-1">
                <GitFork size={11} />
                {repo.forks.toLocaleString()}
              </span>
              {repo.language && (
                <span className="inline-flex items-center gap-1">
                  <span
                    className="h-2 w-2 rounded-full"
                    style={{ backgroundColor: getGitHubLanguageColor(repo.language) }}
                  />
                  {repo.language}
                </span>
              )}
            </div>
            <div className="flex items-center gap-1.5">
              {!isQuickLookHosted && (
                <Button
                  variant="secondary"
                  size="xs"
                  className="flex-1 justify-center"
                  onClick={() => openQuickLook(singleAsset.id)}
                >
                  阅读 README
                </Button>
              )}
              {singleAsset.sourceURL && (
                <a
                  href={singleAsset.sourceURL}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="charkle-pressable h-7 px-2.5 inline-flex items-center justify-center gap-1 rounded-[var(--radius-chip)] bg-[var(--bg-elevated)] hover:bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[var(--text-primary)] text-[11.5px]"
                >
                  <ExternalLink size={12} />
                  {isQuickLookHosted && '打开仓库'}
                </a>
              )}
            </div>
          </div>
        );
        break;
      }

      case 'socialMediaExtract': {
        const post = singleAsset.richMetadata?.socialPost;
        if (!post) return null;
        const attachments = getEffectiveSocialAttachments(post);
        body = (
          <div className="flex flex-col gap-2">
            <div className="flex items-center justify-between">
              <span className="text-[11.5px] font-semibold text-[var(--text-primary)] truncate">
                {socialPlatformDisplayName(post.platform)} · @{post.authorHandle}
              </span>
              <button
                type="button"
                title="重新抓取推文与媒体"
                onClick={async () => {
                  setBusyAction('refresh-rich');
                  try {
                    await refreshRichAsset(singleAsset.id);
                    pushToast({ tone: 'success', message: '已刷新推文内容与媒体' });
                  } finally {
                    setBusyAction(null);
                  }
                }}
                className="p-1 text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
              >
                <RefreshCw
                  size={12}
                  className={busyAction === 'refresh-rich' ? 'animate-spin' : ''}
                />
              </button>
            </div>
            {post.mediaFetchFailed && (
              <div className="px-2 py-1.5 rounded-[6px] bg-[var(--warning-soft)] text-[var(--warning)] text-[11px] flex items-center justify-between">
                <span>部分附件抓取失败</span>
                <button
                  type="button"
                  onClick={() => void refreshRichAsset(singleAsset.id)}
                  className="font-semibold underline cursor-pointer"
                >
                  重试获取
                </button>
              </div>
            )}
            {attachments.length > 0 && (
              <Button
                variant="secondary"
                size="xs"
                loading={busyAction === 'extract-social'}
                onClick={async () => {
                  setBusyAction('extract-social');
                  try {
                    await extractSocialMedia(singleAsset.id, null);
                  } finally {
                    setBusyAction(null);
                  }
                }}
                className="w-full justify-center"
              >
                提取全部媒体为独立素材 ({attachments.length})
              </Button>
            )}
          </div>
        );
        break;
      }
    }

    if (!body) return null;

    return (
      <section
        key={section}
        onDragOver={(e) => {
          if (!draggedSection || draggedSection === section) return;
          e.preventDefault();
          e.dataTransfer.dropEffect = 'move';
          const rect = e.currentTarget.getBoundingClientRect();
          const position: 'before' | 'after' =
            e.clientY - rect.top < rect.height * 0.5 ? 'before' : 'after';
          setDropTarget((prev) =>
            prev?.section === section && prev.position === position ? prev : { section, position },
          );
        }}
        onDragLeave={(e) => {
          if (e.currentTarget.contains(e.relatedTarget as Node | null)) return;
          setDropTarget((prev) => (prev?.section === section ? null : prev));
        }}
        onDrop={(e) => {
          e.preventDefault();
          if (draggedSection && draggedSection !== section) {
            const rect = e.currentTarget.getBoundingClientRect();
            const position: 'before' | 'after' =
              dropTarget?.section === section
                ? dropTarget.position
                : e.clientY - rect.top < rect.height * 0.5
                  ? 'before'
                  : 'after';
            setInspectorSectionOrder(
              moveSectionRelative(draggedSection, section, position, inspectorSectionOrder),
            );
          }
          setDraggedSection(null);
          setDropTarget(null);
        }}
        style={
          rippleOffsetY !== 0 || rippleDelayMs > 0
            ? {
                transform: `translate3d(0, ${rippleOffsetY.toFixed(2)}px, 0)`,
                transitionDelay: `${rippleDelayMs}ms`,
              }
            : undefined
        }
        className={[
          'group/sec relative flex flex-col gap-2 p-2.5 rounded-[var(--radius-settings-outer)]',
          'bg-[var(--bg-elevated)]/82 border border-[var(--border-hairline)]',
          'charkle-drag-ripple-item transition-[transform,opacity,border-color,box-shadow] duration-[220ms] ease-[var(--ease-out)]',
          isDragging ? 'opacity-45' : 'opacity-100',
        ].join(' ')}
      >
        {showLineBefore && (
          <div
            aria-hidden="true"
            className="charkle-drop-line pointer-events-none absolute -top-[6px] inset-x-1 z-20"
          />
        )}
        {showLineAfter && (
          <div
            aria-hidden="true"
            className="charkle-drop-line pointer-events-none absolute -bottom-[6px] inset-x-1 z-20"
          />
        )}

        {/* Drag Handle (strictly scoped to header grip so body text stays 100% selectable) */}
        <div className="flex items-center justify-between gap-1 -mt-0.5">
          <div
            draggable
            onDragStart={(e) => {
              setDraggedSection(section);
              e.dataTransfer.effectAllowed = 'move';
              e.dataTransfer.setData('application/x-charkle-inspector-section', section);
              const secEl = e.currentTarget.closest('section');
              if (secEl) {
                e.dataTransfer.setDragImage(secEl, 24, 16);
              }
            }}
            onDragEnd={() => {
              setDraggedSection(null);
              setDropTarget(null);
            }}
            className="flex items-center gap-1 min-w-0 cursor-grab active:cursor-grabbing select-none text-[var(--text-tertiary)] hover:text-[var(--text-secondary)]"
            title="拖拽调整卡片顺序"
          >
            <GripVertical size={11.5} className="shrink-0 opacity-60 group-hover/sec:opacity-100" />
            <span className="text-[11px] font-semibold text-[var(--text-secondary)] truncate">
              {inspectorInfoSectionTitle(section)}
            </span>
          </div>

          <div className="flex items-center gap-0.5 opacity-0 group-hover/sec:opacity-100 group-focus-within/sec:opacity-100 transition-opacity duration-[130ms] ease-[var(--ease-out)]">
            <button
              type="button"
              disabled={isFirst}
              title="置顶"
              aria-label={`将${inspectorInfoSectionTitle(section)}置顶`}
              onClick={() =>
                setInspectorSectionOrder(moveInspectorSectionToTop(section, inspectorSectionOrder))
              }
              className="h-5 w-5 inline-flex items-center justify-center rounded-[5px] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] disabled:opacity-25 cursor-pointer"
            >
              <ArrowUpToLine size={10.5} />
            </button>
            <button
              type="button"
              disabled={isFirst}
              title="上移"
              aria-label={`将${inspectorInfoSectionTitle(section)}上移`}
              onClick={() =>
                setInspectorSectionOrder(
                  stepInspectorSection(section, -1, visibleSections, inspectorSectionOrder),
                )
              }
              className="h-5 w-5 inline-flex items-center justify-center rounded-[5px] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] disabled:opacity-25 cursor-pointer"
            >
              <ArrowUp size={10.5} />
            </button>
            <button
              type="button"
              disabled={isLast}
              title="下移"
              aria-label={`将${inspectorInfoSectionTitle(section)}下移`}
              onClick={() =>
                setInspectorSectionOrder(
                  stepInspectorSection(section, 1, visibleSections, inspectorSectionOrder),
                )
              }
              className="h-5 w-5 inline-flex items-center justify-center rounded-[5px] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] disabled:opacity-25 cursor-pointer"
            >
              <ArrowDown size={10.5} />
            </button>
            <button
              type="button"
              disabled={isLast}
              title="置底"
              aria-label={`将${inspectorInfoSectionTitle(section)}置底`}
              onClick={() =>
                setInspectorSectionOrder(
                  moveInspectorSectionToBottom(section, inspectorSectionOrder),
                )
              }
              className="h-5 w-5 inline-flex items-center justify-center rounded-[5px] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] disabled:opacity-25 cursor-pointer"
            >
              <ArrowDownToLine size={10.5} />
            </button>
          </div>
        </div>

        {body}
      </section>
    );
  };

  const ambientStyle = singleAsset
    ? computeAmbientTintStyle(singleAsset.dominantColors[0]?.hex, isDark, 'inspector')
    : {};

  const isTrashMulti =
    selectedAssets.length >= 2 &&
    (destination.type === 'trash' || selectedAssets.every((a) => a.isTrashed));
  const allBatchPinned =
    selectedAssets.length >= 2 && selectedAssets.every((a) => Boolean(a.pinnedOffline));

  return (
    <>
      {drawerPresence.rendered && (
        <aside
          aria-hidden={!inspectorOpen}
          data-quicklook-inspector={isQuickLookHosted ? 'true' : undefined}
          data-state={drawerPresence.state}
          className={[
            'relative shrink-0 w-[300px] h-full overflow-hidden select-text',
            'transition-[background-color,border-color] ease-[var(--ease-drawer)]',
            drawerPresence.state === 'open'
              ? 'bg-[var(--bg-inspector)] border-l border-[var(--border-hairline)] duration-[var(--duration-drawer)]'
              : 'bg-transparent border-l border-transparent duration-[220ms] pointer-events-none',
          ].join(' ')}
        >
          <div
            className={[
              'relative w-[300px] h-full flex flex-col overflow-hidden bg-[var(--bg-inspector)]',
              'transition-[opacity,transform] ease-[var(--ease-drawer)]',
              drawerPresence.state === 'open'
                ? 'opacity-100 translate-x-0 duration-[var(--duration-drawer)]'
                : 'opacity-0 translate-x-6 duration-[220ms]',
            ].join(' ')}
          >
            {/* Ultra-subtle top 200px ambient tint strictly in Single Asset mode */}
            {singleAsset && (
              <div
                aria-hidden="true"
                className="pointer-events-none absolute inset-x-0 top-0 h-[200px] z-0"
                style={ambientStyle}
              />
            )}

            {/* Mode 1: Single Asset Inspector */}
            {singleAsset ? (
              <div className="relative z-10 flex-1 min-h-0 flex flex-col">
                {/* Synced Segmented Header */}
                <div className="px-3.5 pt-3 pb-2 shrink-0 flex items-center justify-between gap-2 border-b border-[var(--border-hairline)]">
                  <SegmentedControl
                    options={INSPECTOR_TAB_OPTIONS}
                    value={selectedInspectorTab}
                    onChange={setSelectedInspectorTab}
                    ariaLabel="检查器面板切换"
                    className="w-full grid grid-cols-2"
                  />
                </div>

                {selectedInspectorTab === 'similar' ? (
                  <div
                    onScroll={() => notifyLiveScrolling()}
                    className="flex-1 overflow-y-auto charkle-scroll p-3"
                  >
                    {showSimilarSkeleton ? (
                      <InspectorSimilarSkeleton count={6} />
                    ) : loadingSimilar && similarItems.length === 0 ? null : similarItems.length === 0 ? (
                      <div className="py-10 flex flex-col items-center gap-2 text-center text-[12.5px] text-[var(--text-secondary)]">
                        <EmptyStateVignette kind="noFilterResults" compact />
                        <span>暂无相似素材</span>
                      </div>
                    ) : (
                      <div className="grid grid-cols-2 gap-2">
                        {similarItems.map((item) => (
                          <button
                            key={item.asset.id}
                            type="button"
                            title={item.matchReasons.join(' · ') || item.asset.title}
                            onMouseEnter={() => setHoveredSimilarID(item.asset.id)}
                            onMouseLeave={() =>
                              setHoveredSimilarID((cur) => (cur === item.asset.id ? null : cur))
                            }
                            onMouseDown={() => stopAllHoverPreviews()}
                            onClick={() => {
                              selectAsset(item.asset.id, 'replace');
                              if (isQuickLookHosted) {
                                openQuickLook(item.asset.id);
                              }
                            }}
                            onDoubleClick={(e) =>
                              openQuickLook(item.asset.id, e.currentTarget.getBoundingClientRect())
                            }
                            className="group relative aspect-square overflow-hidden rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] cursor-pointer text-left"
                          >
                            <img
                              src={apiClient.thumbnailURL(item.asset.id, 'grid520', cacheBust)}
                              alt={item.asset.title}
                              className="w-full h-full object-cover charkle-media-zoom"
                            />
                            <HoverMediaPreview
                              asset={item.asset}
                              active={hoveredSimilarID === item.asset.id}
                              fit="cover"
                              roundedClass="rounded-[var(--radius-settings-inner)]"
                            />
                            <span className="absolute bottom-1 right-1 z-20 px-1.5 py-0.5 rounded bg-black/60 text-white text-[10px] font-mono tabular-nums">
                              {Math.round(item.score * 100)}%
                            </span>
                          </button>
                        ))}
                      </div>
                    )}
                  </div>
                ) : (
                  <div className="flex-1 overflow-y-auto charkle-scroll p-3 flex flex-col gap-2.5">
                    {visibleSections.map((section, idx) => renderSectionCard(section, idx))}

                    {isCustomSectionOrder && (
                      <button
                        type="button"
                        onClick={resetInspectorSectionOrder}
                        className="charkle-pressable self-center mt-1 px-2.5 py-1 rounded-[var(--radius-chip)] text-[11px] font-medium text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
                      >
                        恢复默认顺序
                      </button>
                    )}
                  </div>
                )}
              </div>
            ) : selectedAssets.length >= 2 ? (
              /* Mode 2: Multi-Select Batch Edit (dedicated Trash actions vs Normal Library actions) */
              <div className="flex-1 overflow-y-auto charkle-scroll p-4 flex flex-col gap-4">
                <div>
                  <h2 className="text-[15px] font-semibold text-[var(--text-primary)]">
                    已选 {selectedAssets.length} 项素材
                  </h2>
                  <p className="text-[12px] text-[var(--text-secondary)] mt-0.5 tabular-nums">
                    总体积 {formatBytes(selectedAssets.reduce((sum, a) => sum + a.fileSizeBytes, 0))}
                  </p>
                </div>

                {isTrashMulti ? (
                  <div className="flex flex-col gap-2">
                    <Button
                      variant="primary"
                      size="sm"
                      className="w-full justify-center"
                      onClick={() => {
                        const ids = selectedAssets.map((a) => a.id);
                        void restoreAssets(ids);
                        pushToast({ tone: 'success', message: `已恢复 ${ids.length} 项素材` });
                      }}
                    >
                      <RotateCcw size={14} />
                      恢复选中素材
                    </Button>
                    <Button
                      variant="danger"
                      size="sm"
                      className="w-full justify-center"
                      onClick={() =>
                        setConfirmDelete({
                          ids: selectedAssets.map((a) => a.id),
                          title: `彻底删除 ${selectedAssets.length} 项素材？`,
                        })
                      }
                    >
                      <Trash2 size={14} />
                      彻底删除
                    </Button>
                  </div>
                ) : (
                  <>
                    <div className="flex flex-col gap-2">
                      <Button
                        variant="primary"
                        size="sm"
                        className="w-full justify-center"
                        onClick={() => openGeneratorModal(selectedAssets.map((a) => a.id))}
                      >
                        <Sparkles size={14} />
                        用选中素材生成情绪板
                      </Button>
                      {activeBoard && (
                        <Button
                          variant="secondary"
                          size="sm"
                          className="w-full justify-center"
                          onClick={async () => {
                            await addAssetsToBoard(
                              activeBoard.id,
                              selectedAssets.map((a) => a.id),
                            );
                            pushToast({
                              tone: 'success',
                              message: `已将 ${selectedAssets.length} 项加入「${activeBoard.title}」`,
                            });
                          }}
                        >
                          加入「{activeBoard.title}」
                        </Button>
                      )}
                    </div>

                    <div className="flex flex-col gap-2 p-3 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)]">
                      <span className="text-[11.5px] font-semibold text-[var(--text-secondary)]">
                        批量移动到文件夹
                      </span>
                      <button
                        ref={batchFolderBtnRef}
                        type="button"
                        aria-haspopup="menu"
                        aria-expanded={batchFolderMenuOpen}
                        onClick={() => setBatchFolderMenuOpen((v) => !v)}
                        className="charkle-pressable min-h-[32px] px-2.5 text-[12.5px] rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] hover:bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[var(--text-primary)] inline-flex items-center justify-between gap-2 cursor-pointer"
                      >
                        <span className="truncate text-[var(--text-secondary)]">选择目标文件夹…</span>
                        <ChevronDown size={13} className="text-[var(--text-tertiary)] shrink-0" />
                      </button>
                      <Popover
                        open={batchFolderMenuOpen}
                        onOpenChange={setBatchFolderMenuOpen}
                        anchorEl={batchFolderBtnRef.current}
                        placement="bottom-end"
                      >
                        <FolderHierarchyMenu
                          folders={folders}
                          includeInbox
                          parentSelfPrefix="放入"
                          submenuSide="left"
                          onSelectFolder={(folderID) => {
                            setBatchFolderMenuOpen(false);
                            const ids = selectedAssets.map((a) => a.id);
                            void batchPatch(
                              createDefaultAssetBatchPatch(ids, {
                                folderAssignment: folderID
                                  ? { type: 'folder', folderID }
                                  : { type: 'inbox' },
                              }),
                            );
                            const targetLabel = folderID
                              ? foldersByID.get(folderID)?.name ?? '文件夹'
                              : '收件箱';
                            pushToast({
                              tone: 'success',
                              message: `已将 ${ids.length} 项移动到「${targetLabel}」`,
                            });
                          }}
                        />
                      </Popover>
                    </div>

                    <div className="flex flex-col gap-2 p-3 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)]">
                      <label className="text-[11.5px] font-semibold text-[var(--text-secondary)]">
                        批量追加标签
                      </label>
                      <div className="flex gap-1.5">
                        <input
                          type="text"
                          value={batchTagInput}
                          onChange={(e) => setBatchTagInput(e.target.value)}
                          onKeyDown={(e) => {
                            if (e.key === 'Enter') {
                              void handleAddTag(
                                selectedAssets.map((a) => a.id),
                                batchTagInput,
                                () => setBatchTagInput(''),
                              );
                            }
                          }}
                          placeholder="输入标签名…"
                          className="flex-1 min-w-0 min-h-[32px] px-2.5 text-[12px] rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[var(--text-primary)]"
                        />
                        <Button
                          variant="secondary"
                          size="xs"
                          onClick={() =>
                            void handleAddTag(
                              selectedAssets.map((a) => a.id),
                              batchTagInput,
                              () => setBatchTagInput(''),
                            )
                          }
                        >
                          <Tag size={12} />
                        </Button>
                      </div>

                      <Button
                        variant="ghost"
                        size="xs"
                        loading={busyAction === 'ai-analyze'}
                        onClick={() => void handleAnalyzeAI(selectedAssets.map((a) => a.id))}
                        className="w-full justify-center bg-[var(--accent-soft)] text-[var(--accent)] mt-1"
                      >
                        <Sparkles size={12} />
                        批量 AI 智能分析与打标
                      </Button>
                    </div>

                    <div className="flex flex-col gap-2 p-3 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)]">
                      <span className="text-[11.5px] font-semibold text-[var(--text-secondary)]">
                        批量星级评分
                      </span>
                      <div className="flex items-center gap-1">
                        {[1, 2, 3, 4, 5].map((star) => (
                          <button
                            key={star}
                            type="button"
                            onClick={() =>
                              void batchPatch(
                                createDefaultAssetBatchPatch(
                                  selectedAssets.map((a) => a.id),
                                  { rating: star },
                                ),
                              )
                            }
                            className="charkle-pressable p-1 cursor-pointer hover:bg-[var(--bg-subtle)] rounded"
                          >
                            <Star size={16} className="text-[#F2C14E]" />
                          </button>
                        ))}
                      </div>
                    </div>

                    <div className="flex items-center gap-2">
                      <Button
                        variant="secondary"
                        size="xs"
                        className="flex-1 justify-center"
                        onClick={async () => {
                          const nextPinned = !allBatchPinned;
                          const ids = selectedAssets.map((a) => a.id);
                          await batchPatch(
                            createDefaultAssetBatchPatch(ids, { pinnedOffline: nextPinned }),
                          );
                          pushToast({
                            tone: 'success',
                            message: nextPinned
                              ? `已为 ${ids.length} 项素材开启离线保留`
                              : `已取消 ${ids.length} 项素材的离线保留`,
                          });
                        }}
                      >
                        <ArrowDownCircle size={12} />
                        {allBatchPinned ? '取消离线保留' : '离线保留'}
                      </Button>
                      <Button
                        variant="danger"
                        size="xs"
                        className="flex-1 justify-center"
                        onClick={() => void trashAssets(selectedAssets.map((a) => a.id))}
                      >
                        <Trash2 size={12} />
                        移入回收站
                      </Button>
                    </div>
                  </>
                )}
              </div>
            ) : (
              /* Mode 3: Empty Inspector State with Miniature Vignette */
              <div className="flex-1 flex flex-col items-center justify-center p-6 text-center gap-2.5">
                <EmptyStateVignette kind="emptyInspector" compact />
                <div className="text-[13px] font-medium text-[var(--text-primary)]">未选中素材</div>
              </div>
            )}
          </div>
        </aside>
      )}

      <ConfirmDialog
        open={Boolean(confirmDelete)}
        onClose={() => setConfirmDelete(null)}
        title={confirmDelete?.title ?? '彻底删除素材？'}
        description="彻底删除后将无法恢复，相关本地与云端记录也会一并清除。"
        confirmLabel="彻底删除"
        tone="danger"
        onConfirm={async () => {
          if (!confirmDelete) return;
          const { ids, closeQuickLookAfter } = confirmDelete;
          await permanentlyDeleteAssets(ids);
          if (closeQuickLookAfter) {
            onRequestCloseQuickLook?.();
          }
          pushToast({ tone: 'info', message: `已彻底删除 ${ids.length} 项素材` });
        }}
      />
    </>
  );
};
