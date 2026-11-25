import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  AlignBottom16Regular,
  AlignTop16Regular,
  ArrowCircleDown16Regular,
  ArrowDown16Regular,
  ArrowReset20Regular,
  ArrowSync16Regular,
  ArrowUp16Regular,
  Camera16Regular,
  ChevronUpDown16Regular,
  Code16Regular,
  Color16Regular,
  Copy16Regular,
  Cut16Regular,
  Delete16Regular,
  Dismiss16Regular,
  DocumentText16Regular,
  Filmstrip16Regular,
  Flash16Regular,
  Folder16Regular,
  FolderOpen16Regular,
  Image16Regular,
  ImageMultiple16Regular,
  ImageOff20Regular,
  Info16Regular,
  LayerDiagonal16Regular,
  Location16Regular,
  NumberSymbol16Regular,
  Open16Regular,
  Options16Regular,
  ScanText16Regular,
  Share16Regular,
  Sparkle16Regular,
  Star16Filled,
  Star16Regular,
} from '@fluentui/react-icons';
import { getTransport, isTauriRuntime } from '../../api/transport';
import {
  Button,
  CharkleIcon,
  EmptyStateVignette,
  InspectorSimilarSkeleton,
  Popover,
  SegmentedControl,
  computeAmbientTintStyle,
  formatBytes,
  formatDuration,
  hasMeaningfulCameraExif,
  useDelayedFlag,
  useResolvedIsDark,
} from '../../design-system';
import {
  getEffectiveSocialAttachments,
  getFolderDisplayPath,
  isInspectorCardOrderCustomized,
  isPlainWebBookmark,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  type InspectorCardId,
  type InspectorTab,
} from '../../stores';
import {
  formatSocialDisplayHandle,
  mediaKindLabel,
  resolveSocialMediaUrl,
  type AIGenerationMetadata,
  type AssetRecord,
  type PhotoExifMetadata,
  type ScoredAsset,
  type SocialMediaAttachment,
} from '../../types/domain';
import { beginPointerDrag, wasRecentPointerDrag } from '../dnd/PointerDragContext';
import { FolderMoveMenu } from '../sidebar/FolderMoveMenu';

// ---------------------------------------------------------------------------
// Formatting & Metadata Helpers (1:1 macOS CoreModels.swift parity)
// ---------------------------------------------------------------------------

function withThumbCacheBust(url: string, version?: string | number | null): string {
  if (version == null || version === '' || url.startsWith('data:') || url.startsWith('blob:')) {
    return url;
  }
  const sep = url.includes('?') ? '&' : '?';
  return `${url}${sep}v=${encodeURIComponent(String(version))}`;
}

function formatBookmarkDomain(asset: Pick<AssetRecord, 'sourceDomain' | 'sourceURL'>): string {
  if (asset.sourceDomain?.trim()) {
    return asset.sourceDomain.trim().replace(/^www\./i, '');
  }
  if (asset.sourceURL) {
    try {
      return new URL(asset.sourceURL).host.toLowerCase().replace(/^www\./, '');
    } catch {
      // Fallback below
    }
  }
  return '网页';
}

function aspectShapeLabel(width: number, height: number): string {
  if (width <= 0 || height <= 0) return '方图';
  const ratio = width / height;
  if (ratio >= 2.0) return '超宽图';
  if (ratio > 1.08) return '横图';
  if (ratio < 0.92) return '竖图';
  return '方图';
}

function displayTypeLabel(asset: AssetRecord): string {
  if (asset.richMetadata?.githubRepo) return 'GitHub 仓库';
  if (asset.richMetadata?.socialPost) {
    const p = asset.richMetadata.socialPost.platform;
    if (p === 'x') return 'X 动态';
    if (p === 'threads') return 'Threads 动态';
    if (p === 'bluesky') return 'Bluesky 动态';
    if (p === 'xiaohongshu') return '小红书笔记';
  }
  const lower = asset.fileName.toLowerCase();
  if (lower.endsWith('.swatch')) return '灵感色卡';
  if (asset.mediaKind === 'document') {
    if (lower.endsWith('.pdf') || asset.mimeType === 'application/pdf') return 'PDF 文档';
    if (asset.richMetadata?.isMarkdown || lower.endsWith('.md') || lower.endsWith('.markdown')) {
      return 'Markdown 文档';
    }
  }
  return mediaKindLabel(asset.mediaKind);
}

function hasMeaningfulAIGeneration(ai: AIGenerationMetadata | null | undefined): boolean {
  if (!ai) return false;
  return Boolean(
    ai.prompt?.trim() ||
      ai.negativePrompt?.trim() ||
      ai.modelName?.trim() ||
      ai.sampler?.trim() ||
      ai.seed?.trim() ||
      ai.steps != null ||
      ai.cfgScale != null ||
      ai.loras.length > 0 ||
      ai.rawParameters?.trim(),
  );
}

function formatCameraName(exif: PhotoExifMetadata): string | null {
  const make = exif.cameraMake?.trim() ?? '';
  const model = exif.cameraModel?.trim() ?? '';
  if (!make && !model) return null;
  if (make && model) {
    if (model.toLowerCase().includes(make.toLowerCase())) return model;
    return `${make} ${model}`;
  }
  return model || make;
}

function formatFocalLength(exif: PhotoExifMetadata): string | null {
  if (exif.focalLengthMM == null || exif.focalLengthMM <= 0) return null;
  const base = Number.isInteger(exif.focalLengthMM)
    ? `${exif.focalLengthMM}mm`
    : `${exif.focalLengthMM.toFixed(1).replace(/\.0$/, '')}mm`;
  if (exif.focalLength35mm && exif.focalLength35mm > 0 && Math.abs(exif.focalLength35mm - exif.focalLengthMM) >= 1) {
    return `${base} (等效 ${Math.round(exif.focalLength35mm)}mm)`;
  }
  return base;
}

function formatAperture(fNumber: number | null | undefined): string | null {
  if (fNumber == null || fNumber <= 0) return null;
  return `f/${fNumber.toFixed(1).replace(/\.0$/, '')}`;
}

function formatExposureSummary(exif: PhotoExifMetadata): string | null {
  const parts: string[] = [];
  if (exif.focalLengthMM != null && exif.focalLengthMM > 0) {
    parts.push(`${Math.round(exif.focalLengthMM)}mm`);
  }
  const ap = formatAperture(exif.fNumber);
  if (ap) parts.push(ap);
  if (exif.exposureTime?.trim()) parts.push(exif.exposureTime.trim());
  if (exif.iso != null && exif.iso > 0) parts.push(`ISO ${exif.iso}`);
  return parts.length > 0 ? parts.join(' · ') : null;
}

function parseTagInput(raw: string): string[] {
  return raw
    .split(/[,，]/)
    .map((part) => part.replace(/^[#＃]+/, '').trim())
    .filter(Boolean);
}

// ---------------------------------------------------------------------------
// Visual Primitives (Exact macOS InspectorView.swift proportions & hairlines)
// ---------------------------------------------------------------------------

const InspectorInnerDivider: React.FC = () => (
  <div className="h-px w-full bg-[var(--win-stroke-divider)]" />
);

const InspectorRowDivider: React.FC = () => (
  <div className="h-px w-full bg-[var(--win-stroke-divider)] opacity-65" />
);

const SpecRow: React.FC<{ label: string; value: React.ReactNode }> = ({ label, value }) => (
  <div className="flex items-center justify-between gap-2 py-[5px] text-[11px]">
    <span className="text-[var(--text-secondary)] shrink-0">{label}</span>
    <span className="font-medium text-[var(--text-primary)]/90 text-right charkle-tabular truncate min-w-0">
      {value}
    </span>
  </div>
);

/** 6-dot vertical grip matching macOS `InspectorDragGripDots`. */
const InspectorDragGripDots: React.FC<{ highlighted: boolean }> = ({ highlighted }) => (
  <span
    aria-hidden="true"
    className={[
      'inline-grid grid-cols-2 gap-[2.2px] px-[3px] py-[2px] shrink-0 transition-opacity duration-120',
      highlighted ? 'opacity-65' : 'opacity-25',
    ].join(' ')}
  >
    {[0, 1, 2, 3, 4, 5].map((i) => (
      <span
        key={i}
        className="w-[2.2px] h-[2.2px] rounded-full bg-current text-[var(--text-primary)]"
      />
    ))}
  </span>
);

interface ActiveCardDragState {
  cardId: InspectorCardId;
  title: string;
  icon: React.ReactNode;
  x: number;
  y: number;
}

interface CardSectionShellProps {
  cardId?: InspectorCardId;
  title: string;
  icon: React.ReactNode;
  trailing?: React.ReactNode;
  isDraggingSelf?: boolean;
  onStartHeaderDrag?: (
    e: React.PointerEvent<HTMLDivElement>,
    cardId: InspectorCardId,
    title: string,
    icon: React.ReactNode,
  ) => void;
  onHeaderContextMenu?: (e: React.MouseEvent<HTMLDivElement>, cardId: InspectorCardId) => void;
  children: React.ReactNode;
}

const InspectorSectionCard: React.FC<CardSectionShellProps> = ({
  cardId,
  title,
  icon,
  trailing,
  isDraggingSelf = false,
  onStartHeaderDrag,
  onHeaderContextMenu,
  children,
}) => {
  const [hovered, setHovered] = useState(false);
  const reorderable = Boolean(cardId && onStartHeaderDrag);

  return (
    <section
      data-inspector-card={cardId}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      className={[
        'rounded-[var(--win-radius-card)] bg-[var(--bg-elevated)] border p-3 flex flex-col gap-[9px] shadow-[0_1px_2px_rgba(0,0,0,0.03)] dark:shadow-[0_1px_2px_rgba(0,0,0,0.2)] transition-opacity duration-150',
        isDraggingSelf
          ? 'opacity-35 border-dashed border-[var(--accent)]/60'
          : 'border-[var(--win-stroke-card)]',
      ].join(' ')}
    >
      <div
        onPointerDown={
          reorderable && cardId && onStartHeaderDrag
            ? (e) => onStartHeaderDrag(e, cardId, title, icon)
            : undefined
        }
        onContextMenu={
          reorderable && cardId && onHeaderContextMenu
            ? (e) => onHeaderContextMenu(e, cardId)
            : undefined
        }
        title={
          reorderable
            ? '按住标题栏拖拽可自由调整排序 · 右键可快速置顶或恢复默认'
            : undefined
        }
        className={[
          'flex items-center gap-[5px] select-none',
          reorderable ? 'cursor-grab active:cursor-grabbing' : '',
        ].join(' ')}
      >
        <span className="shrink-0 text-[var(--text-secondary)] inline-flex items-center">
          {icon}
        </span>
        <span className="text-[11.5px] font-semibold text-[var(--text-primary)]/86 truncate">
          {title}
        </span>
        <span className="flex-1 min-w-[4px]" />
        {trailing && (
          <div data-no-card-drag="true" className="shrink-0 flex items-center gap-1">
            {trailing}
          </div>
        )}
        {reorderable && (
          <InspectorDragGripDots highlighted={hovered || isDraggingSelf} />
        )}
      </div>

      {children}
    </section>
  );
};

// ---------------------------------------------------------------------------
// Main Component
// ---------------------------------------------------------------------------

export interface InspectorViewProps {
  /** When hosted inside Quick Look, pin directly to the active previewed asset. */
  pinnedAsset?: AssetRecord | null;
  isQuickLookHosted?: boolean;
  onRequestCloseQuickLook?: () => void;
}

export const InspectorView: React.FC<InspectorViewProps> = ({
  pinnedAsset = null,
  isQuickLookHosted = false,
  onRequestCloseQuickLook,
}) => {
  const destination = useCoordinatorStore((s) => s.destination);
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const inspectorTab = useCoordinatorStore((s) => s.inspectorTab);
  const setInspectorTab = useCoordinatorStore((s) => s.setInspectorTab);
  const inspectorCardOrder = useCoordinatorStore((s) => s.inspectorCardOrder);
  const moveInspectorCard = useCoordinatorStore((s) => s.moveInspectorCard);
  const moveInspectorCardToTop = useCoordinatorStore((s) => s.moveInspectorCardToTop);
  const moveInspectorCardToBottom = useCoordinatorStore((s) => s.moveInspectorCardToBottom);
  const stepInspectorCard = useCoordinatorStore((s) => s.stepInspectorCard);
  const resetInspectorCardOrder = useCoordinatorStore((s) => s.resetInspectorCardOrder);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const setDestination = useCoordinatorStore((s) => s.setDestination);
  const setVisualFilterBarOpen = useCoordinatorStore((s) => s.setVisualFilterBarOpen);
  const openMoodboardGenerator = useCoordinatorStore((s) => s.openMoodboardGenerator);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const assets = useLibraryStore((s) => s.assets);
  const allAssets = useLibraryStore((s) => s.allAssets);
  const folders = useLibraryStore((s) => s.folders);
  const updateAssets = useLibraryStore((s) => s.updateAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);
  const cutAssets = useLibraryStore((s) => s.cutAssets);
  const setCriteria = useLibraryStore((s) => s.setCriteria);
  const refreshRichAsset = useLibraryStore((s) => s.refreshRichAsset);
  const markAssetOpened = useLibraryStore((s) => s.markAssetOpened);
  const hydrateImageMetadata = useLibraryStore((s) => s.hydrateImageMetadata);
  const patchSingleAssetInMemory = useLibraryStore((s) => s.patchSingleAssetInMemory);
  const extractSocialAttachment = useLibraryStore((s) => s.extractSocialAttachment);
  const extractAllSocialAttachments = useLibraryStore((s) => s.extractAllSocialAttachments);

  const boards = useMoodboardStore((s) => s.boards);
  const createBoard = useMoodboardStore((s) => s.createBoard);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);
  const openBoard = useMoodboardStore((s) => s.openBoard);

  const isDark = useResolvedIsDark();

  const selectedAssets = useMemo(() => {
    if (pinnedAsset) return [pinnedAsset];
    const idSet = new Set(selectedAssetIds);
    const inView = assets.filter((a) => idSet.has(a.id));
    if (inView.length === idSet.size || allAssets.length === 0) return inView;
    const foundIds = new Set(inView.map((a) => a.id));
    const extras = allAssets.filter((a) => idSet.has(a.id) && !foundIds.has(a.id));
    return [...inView, ...extras];
  }, [pinnedAsset, assets, allAssets, selectedAssetIds]);

  const asset: AssetRecord | null = selectedAssets.length === 1 ? selectedAssets[0] : null;

  // Frame-0 zero-flicker draft binding
  const [boundAssetId, setBoundAssetId] = useState<string | null>(asset?.id ?? null);
  const [titleDraft, setTitleDraft] = useState(asset?.title ?? '');
  const [notesDraft, setNotesDraft] = useState(asset?.notes ?? '');
  const [newTagDraft, setNewTagDraft] = useState('');
  const [batchTagDraft, setBatchTagDraft] = useState('');
  const [refreshingRichAssetId, setRefreshingRichAssetId] = useState<string | null>(null);
  const [runningOcrAssetId, setRunningOcrAssetId] = useState<string | null>(null);
  const [extractingKey, setExtractingKey] = useState<string | null>(null);
  const [creatingBatchBoard, setCreatingBatchBoard] = useState(false);
  const [previewFallbackThumb, setPreviewFallbackThumb] = useState(false);
  const [previewLoadFailed, setPreviewLoadFailed] = useState(false);
  const [socialAvatarFailed, setSocialAvatarFailed] = useState(false);
  const [failedSocialThumbKeys, setFailedSocialThumbKeys] = useState<Record<string, boolean>>({});
  const [thumbBustNonce, setThumbBustNonce] = useState(0);

  if ((asset?.id ?? null) !== boundAssetId) {
    setBoundAssetId(asset?.id ?? null);
    setTitleDraft(asset?.title ?? '');
    setNotesDraft(asset?.notes ?? '');
    setNewTagDraft('');
    setPreviewFallbackThumb(false);
    setPreviewLoadFailed(false);
    setSocialAvatarFailed(false);
    setFailedSocialThumbKeys({});
  }

  useEffect(() => {
    setPreviewFallbackThumb(false);
    setPreviewLoadFailed(false);
  }, [asset?.id, asset?.updatedAt, thumbBustNonce]);

  // Reset multi-select draft when leaving multi-select mode
  useEffect(() => {
    if (selectedAssets.length <= 1) {
      setBatchTagDraft('');
    }
  }, [selectedAssets.length]);

  // Flush pending debounced notes deterministically on asset switch AND unmount
  // so rapid Asset A -> Asset B switches NEVER drop Asset A's notes or leak into Asset B.
  const notesTimerRef = useRef<number | null>(null);
  const pendingNotesRef = useRef<{ assetId: string; value: string } | null>(null);
  const lastSavedNotesRef = useRef<{ assetId: string | null; value: string }>({
    assetId: asset?.id ?? null,
    value: asset?.notes ?? '',
  });

  const flushPendingNotes = useCallback(() => {
    if (notesTimerRef.current !== null) {
      window.clearTimeout(notesTimerRef.current);
      notesTimerRef.current = null;
    }
    const pending = pendingNotesRef.current;
    if (!pending) return;
    pendingNotesRef.current = null;
    const liveDest = useCoordinatorStore.getState().destination;
    void updateAssets({ assetIDs: [pending.assetId], notes: pending.value }, liveDest).catch(
      () => {},
    );
  }, [updateAssets]);

  useEffect(() => {
    // Sync lastSaved snapshot for current asset once any prior pending flush finishes
    if (!pendingNotesRef.current || pendingNotesRef.current.assetId !== (asset?.id ?? null)) {
      lastSavedNotesRef.current = {
        assetId: asset?.id ?? null,
        value: asset?.notes ?? '',
      };
    }
  }, [asset?.id, asset?.notes]);

  useEffect(() => {
    return () => {
      flushPendingNotes();
    };
  }, [asset?.id, flushPendingNotes]);

  // Menus & confirmations
  const [boardMenuOpen, setBoardMenuOpen] = useState(false);
  const [folderMenuOpen, setFolderMenuOpen] = useState(false);
  const [batchFolderMenuOpen, setBatchFolderMenuOpen] = useState(false);
  const [pendingDeleteIds, setPendingDeleteIds] = useState<string[]>([]);
  const [swatchMenu, setSwatchMenu] = useState<{
    hex: string;
    point: { x: number; y: number };
  } | null>(null);
  const [suggestedTagMenu, setSuggestedTagMenu] = useState<{
    tag: string;
    point: { x: number; y: number };
  } | null>(null);
  const [cardContextMenu, setCardContextMenu] = useState<{
    cardId: InspectorCardId;
    point: { x: number; y: number };
  } | null>(null);

  const boardBtnRef = useRef<HTMLButtonElement | null>(null);
  const folderBtnRef = useRef<HTMLButtonElement | null>(null);
  const batchFolderBtnRef = useRef<HTMLButtonElement | null>(null);

  // Self-contained live pointer-capture drag-to-reorder (zero PointerDragContext unmount bugs!)
  const [activeCardDrag, setActiveCardDrag] = useState<ActiveCardDragState | null>(null);
  const dragSessionRef = useRef<{
    cardId: InspectorCardId;
    title: string;
    icon: React.ReactNode;
    pointerId: number;
    captureEl: HTMLElement | null;
    startX: number;
    startY: number;
    active: boolean;
    lastSwappedTarget: InspectorCardId | null;
    lastSwapAt: number;
  } | null>(null);

  const visibleSections = useMemo<InspectorCardId[]>(() => {
    if (!asset) return [];
    const exif = asset.richMetadata?.photoExif;
    const aiGen = asset.richMetadata?.aiGeneration;
    const hasSocialMedia =
      getEffectiveSocialAttachments(asset.richMetadata?.socialPost).length > 0;
    return inspectorCardOrder.filter((section) => {
      switch (section) {
        case 'previewIdentity':
        case 'quickActions':
        case 'colorsAndTags':
        case 'notesAndOCR':
        case 'mediaSpecs':
          return true;
        case 'aiGeneration':
          return hasMeaningfulAIGeneration(aiGen);
        case 'photoExif':
          return hasMeaningfulCameraExif(exif);
        case 'githubRepo':
          return Boolean(asset.richMetadata?.githubRepo);
        case 'socialMediaExtract':
          return hasSocialMedia;
      }
    });
  }, [asset, inspectorCardOrder]);

  const finishCardDrag = useCallback(() => {
    const sess = dragSessionRef.current;
    if (sess?.captureEl) {
      try {
        if (sess.captureEl.hasPointerCapture?.(sess.pointerId)) {
          sess.captureEl.releasePointerCapture(sess.pointerId);
        }
      } catch {
        // Ignore if element unmounted
      }
    }
    dragSessionRef.current = null;
    setActiveCardDrag(null);
  }, []);

  useEffect(() => {
    if (pendingDeleteIds.length === 0) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        setPendingDeleteIds([]);
      }
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, [pendingDeleteIds.length]);

  useEffect(() => {
    const handlePointerMove = (e: PointerEvent) => {
      const sess = dragSessionRef.current;
      if (!sess || e.pointerId !== sess.pointerId) return;

      const dist = Math.hypot(e.clientX - sess.startX, e.clientY - sess.startY);
      if (!sess.active) {
        if (dist < 4) return;
        sess.active = true;
      }

      setActiveCardDrag({
        cardId: sess.cardId,
        title: sess.title,
        icon: sess.icon,
        x: e.clientX,
        y: e.clientY,
      });

      if (typeof document === 'undefined' || !document.elementsFromPoint) return;
      const els = document.elementsFromPoint(e.clientX, e.clientY);
      let hoveredEl: HTMLElement | null = null;
      for (const raw of els) {
        const el = raw as HTMLElement;
        if (el.dataset?.inspectorCard) {
          hoveredEl = el;
          break;
        }
      }
      if (!hoveredEl) return;
      const targetId = hoveredEl.dataset.inspectorCard as InspectorCardId;
      if (!targetId || targetId === sess.cardId) {
        sess.lastSwappedTarget = null;
        return;
      }

      const now = Date.now();
      if (sess.lastSwappedTarget === targetId && now - sess.lastSwapAt < 180) {
        return;
      }

      // Direction-aware midpoint hysteresis so tall & short cards swap cleanly without jitter
      const currentOrder = useCoordinatorStore.getState().inspectorCardOrder;
      const fromIdx = currentOrder.indexOf(sess.cardId);
      const toIdx = currentOrder.indexOf(targetId);
      if (fromIdx === -1 || toIdx === -1) return;

      const rect = hoveredEl.getBoundingClientRect();
      const thresholdY =
        fromIdx < toIdx ? rect.top + rect.height * 0.22 : rect.bottom - rect.height * 0.22;
      const crossed = fromIdx < toIdx ? e.clientY >= thresholdY : e.clientY <= thresholdY;
      if (!crossed) return;

      sess.lastSwappedTarget = targetId;
      sess.lastSwapAt = now;
      moveInspectorCard(sess.cardId, targetId);
    };

    const handlePointerUp = (e: PointerEvent) => {
      const sess = dragSessionRef.current;
      if (!sess || e.pointerId !== sess.pointerId) return;
      finishCardDrag();
    };

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && dragSessionRef.current) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        finishCardDrag();
      }
    };

    window.addEventListener('pointermove', handlePointerMove, true);
    window.addEventListener('pointerup', handlePointerUp, true);
    window.addEventListener('pointercancel', handlePointerUp, true);
    window.addEventListener('keydown', handleKeyDown, true);
    return () => {
      window.removeEventListener('pointermove', handlePointerMove, true);
      window.removeEventListener('pointerup', handlePointerUp, true);
      window.removeEventListener('pointercancel', handlePointerUp, true);
      window.removeEventListener('keydown', handleKeyDown, true);
    };
  }, [finishCardDrag, moveInspectorCard]);

  const handleStartHeaderDrag = useCallback(
    (
      e: React.PointerEvent<HTMLDivElement>,
      cardId: InspectorCardId,
      title: string,
      icon: React.ReactNode,
    ) => {
      if (e.button !== 0) return;
      if ((e.target as HTMLElement).closest('button, input, a, [data-no-card-drag="true"]')) {
        return;
      }
      e.preventDefault();
      try {
        e.currentTarget.setPointerCapture?.(e.pointerId);
      } catch {
        // Ignore in synthetic jsdom pointer events
      }
      dragSessionRef.current = {
        cardId,
        title,
        icon,
        pointerId: e.pointerId,
        captureEl: e.currentTarget,
        startX: e.clientX,
        startY: e.clientY,
        active: false,
        lastSwappedTarget: null,
        lastSwapAt: 0,
      };
    },
    [],
  );

  const handleHeaderContextMenu = useCallback(
    (e: React.MouseEvent<HTMLDivElement>, cardId: InspectorCardId) => {
      e.preventDefault();
      e.stopPropagation();
      setCardContextMenu({ cardId, point: { x: e.clientX, y: e.clientY } });
    },
    [],
  );

  // Lazy similar assets & EXIF hydration
  const [similar, setSimilar] = useState<ScoredAsset[]>([]);
  const [loadingSimilar, setLoadingSimilar] = useState(false);
  const hydratedIdsRef = useRef<Set<string>>(new Set());

  useEffect(() => {
    let cancelled = false;
    if (!asset) {
      setSimilar([]);
      setLoadingSimilar(false);
      return;
    }

    setSimilar([]);
    setLoadingSimilar(true);
    void getTransport()
      .similarAssets(asset.id, 12)
      .then((res) => {
        if (!cancelled) {
          setSimilar(res);
          setLoadingSimilar(false);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setSimilar([]);
          setLoadingSimilar(false);
        }
      });

    if (
      (asset.mediaKind === 'image' ||
        asset.mediaKind === 'animatedImage' ||
        asset.mediaKind === 'designFile') &&
      !asset.richMetadata?.photoExif &&
      !asset.richMetadata?.aiGeneration &&
      !hydratedIdsRef.current.has(asset.id)
    ) {
      hydratedIdsRef.current.add(asset.id);
      void hydrateImageMetadata(asset.id);
    }

    return () => {
      cancelled = true;
    };
  }, [
    asset?.id,
    asset?.updatedAt,
    asset?.mediaKind,
    asset?.richMetadata?.photoExif,
    asset?.richMetadata?.aiGeneration,
    hydrateImageMetadata,
  ]);

  const showSimilarSkeleton = useDelayedFlag(loadingSimilar && similar.length === 0, 300, 500);

  const copyText = async (text: string, toastMessage: string) => {
    if (!navigator.clipboard?.writeText) {
      pushToast({ message: '当前环境不支持直接写入剪贴板', tone: 'error', durationMs: 2400 });
      return;
    }
    try {
      await navigator.clipboard.writeText(text);
      pushToast({ message: toastMessage, tone: 'success', durationMs: 2200 });
    } catch {
      pushToast({ message: '无法写入系统剪贴板', tone: 'error', durationMs: 2400 });
    }
  };

  const handleFilterByColor = (hex: string) => {
    if (isQuickLookHosted) {
      onRequestCloseQuickLook?.();
    }
    setDestination({ type: 'allItems' });
    setVisualFilterBarOpen(true);
    void setCriteria({ selectedColorHex: hex.toUpperCase() }, { type: 'allItems' });
  };

  const commitTitle = (targetAsset: AssetRecord) => {
    const trimmed = titleDraft.trim();
    if (!trimmed) {
      setTitleDraft(targetAsset.title);
      return;
    }
    if (trimmed !== targetAsset.title) {
      void updateAssets({ assetIDs: [targetAsset.id], title: trimmed }, destination);
    }
  };

  const handleNotesChange = (targetAsset: AssetRecord, value: string) => {
    setNotesDraft(value);
    const savedValue =
      lastSavedNotesRef.current.assetId === targetAsset.id
        ? lastSavedNotesRef.current.value
        : targetAsset.notes;
    if (value !== savedValue) {
      pendingNotesRef.current = { assetId: targetAsset.id, value };
    } else if (pendingNotesRef.current?.assetId === targetAsset.id) {
      pendingNotesRef.current = null;
    }
    if (notesTimerRef.current !== null) {
      window.clearTimeout(notesTimerRef.current);
    }
    notesTimerRef.current = window.setTimeout(() => {
      notesTimerRef.current = null;
      const pending = pendingNotesRef.current;
      if (pending && pending.assetId === targetAsset.id) {
        pendingNotesRef.current = null;
        lastSavedNotesRef.current = { assetId: targetAsset.id, value: pending.value };
        const liveDest = useCoordinatorStore.getState().destination;
        void updateAssets({ assetIDs: [targetAsset.id], notes: pending.value }, liveDest).catch(
          () => {},
        );
      }
    }, 450);
  };

  const flushNotesNow = (targetAsset: AssetRecord) => {
    if (notesTimerRef.current !== null) {
      window.clearTimeout(notesTimerRef.current);
      notesTimerRef.current = null;
    }
    const savedValue =
      lastSavedNotesRef.current.assetId === targetAsset.id
        ? lastSavedNotesRef.current.value
        : targetAsset.notes;
    if (
      pendingNotesRef.current?.assetId === targetAsset.id ||
      notesDraft !== savedValue
    ) {
      const valueToSave =
        pendingNotesRef.current?.assetId === targetAsset.id
          ? pendingNotesRef.current.value
          : notesDraft;
      pendingNotesRef.current = null;
      lastSavedNotesRef.current = { assetId: targetAsset.id, value: valueToSave };
      const liveDest = useCoordinatorStore.getState().destination;
      void updateAssets({ assetIDs: [targetAsset.id], notes: valueToSave }, liveDest).catch(
        () => {},
      );
    }
  };

  const folderLabelFor = (folderId: string | null | undefined): string => {
    if (!folderId) return '收件箱';
    return folders.find((f) => f.id === folderId)?.name ?? '文件夹';
  };

  const ambientStyle = computeAmbientTintStyle(
    asset?.dominantColors[0]?.hex,
    isDark,
    'inspector',
  );
  const transport = getTransport();
  const isOrderCustomized = isInspectorCardOrderCustomized(inspectorCardOrder);

  // -------------------------------------------------------------------------
  // Single Asset 9-Section Card Renderer
  // -------------------------------------------------------------------------

  const renderSingleAssetCard = (section: InspectorCardId, targetAsset: AssetRecord) => {
    const isDraggingSelf = activeCardDrag?.cardId === section;

    if (section === 'previewIdentity') {
      const rawRatio =
        targetAsset.pixelWidth > 0 && targetAsset.pixelHeight > 0
          ? targetAsset.pixelWidth / targetAsset.pixelHeight
          : 4 / 3;
      const naturalRatio = Math.max(0.35, Math.min(3.2, rawRatio));
      const previewContentWidth = 252;
      const fittedHeight = Math.min(
        280,
        Math.max(108, Math.round(previewContentWidth / naturalRatio)),
      );
      const fittedWidth = Math.min(
        previewContentWidth,
        Math.round(fittedHeight * naturalRatio),
      );
      const thumbVersion = thumbBustNonce > 0
        ? `${String(targetAsset.updatedAt ?? 0)}-${thumbBustNonce}`
        : targetAsset.updatedAt;
      const previewSrc = withThumbCacheBust(
        previewFallbackThumb
          ? transport.thumbnailUrl(targetAsset.id, 'grid520')
          : transport.thumbnailUrl(targetAsset.id, 'preview1400'),
        thumbVersion,
      );
      const plainBookmark = isPlainWebBookmark(targetAsset);

      return (
        <InspectorSectionCard
          key="previewIdentity"
          cardId="previewIdentity"
          title="素材预览"
          icon={<Image16Regular className="w-3.5 h-3.5" />}
          isDraggingSelf={isDraggingSelf}
          onStartHeaderDrag={handleStartHeaderDrag}
          onHeaderContextMenu={handleHeaderContextMenu}
        >
          <div className="flex flex-col gap-2.5">
            {/* Uncropped proportional preview (1:1 macOS formula, shown in both main & Quick Look) */}
            <div className="w-full flex items-center justify-center">
              <button
                type="button"
                onClick={() => {
                  if (plainBookmark && targetAsset.sourceURL) {
                    const domain = formatBookmarkDomain(targetAsset);
                    void transport
                      .openExternalUrl(targetAsset.sourceURL)
                      .then(() => {
                        pushToast({
                          message: `已在默认浏览器中打开 ${domain}`,
                          tone: 'info',
                        });
                      })
                      .catch(() => {
                        pushToast({ message: '无法在默认浏览器中打开链接', tone: 'error' });
                      });
                    void markAssetOpened(targetAsset.id);
                    return;
                  }
                  if (!isQuickLookHosted) {
                    openQuickLook(targetAsset.id, null);
                  }
                }}
                title={
                  plainBookmark
                    ? '点击在默认浏览器中打开网页'
                    : isQuickLookHosted
                      ? targetAsset.title
                      : '点击打开 Quick Look 全屏预览'
                }
                style={{ width: fittedWidth, height: fittedHeight }}
                className={[
                  'group relative rounded-[var(--win-radius-card)] overflow-hidden border border-[var(--win-stroke-card)] bg-[var(--bg-subtle)]/40 flex items-center justify-center',
                  isQuickLookHosted && !plainBookmark
                    ? 'cursor-default'
                    : 'cursor-pointer charkle-pressable',
                ].join(' ')}
              >
                {previewLoadFailed ? (
                  <div className="w-full h-full flex flex-col items-center justify-center gap-1.5 text-[var(--text-tertiary)]">
                    <ImageOff20Regular className="w-5 h-5" />
                    <span className="text-[10.5px]">预览暂不可用</span>
                  </div>
                ) : (
                  <img
                    src={previewSrc}
                    alt={targetAsset.title}
                    draggable={false}
                    onError={() => {
                      if (!previewFallbackThumb) setPreviewFallbackThumb(true);
                      else setPreviewLoadFailed(true);
                    }}
                    className="w-full h-full object-contain"
                  />
                )}
                {plainBookmark && (
                  <span className="pointer-events-none absolute bottom-1.5 right-1.5 h-6 w-6 rounded-full bg-black/60 text-white inline-flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity duration-150">
                    <Open16Regular className="w-3.5 h-3.5" />
                  </span>
                )}
              </button>
            </div>

            <InspectorInnerDivider />

            <div className="flex flex-col gap-2">
              <input
                type="text"
                value={titleDraft}
                aria-label="素材标题"
                placeholder="素材标题"
                onChange={(e) => setTitleDraft(e.target.value)}
                onBlur={() => commitTitle(targetAsset)}
                onKeyDown={(e) => {
                  if (e.nativeEvent.isComposing || e.keyCode === 229) return;
                  if (e.key === 'Enter') {
                    e.currentTarget.blur();
                  }
                }}
                className="w-full px-1.5 -mx-1.5 py-0.5 rounded-[var(--win-radius-control)] bg-transparent hover:bg-[var(--win-subtle-hover)] focus:bg-[var(--bg-inspector-field)] border border-transparent focus:border-[var(--accent)] text-[13.5px] font-semibold text-[var(--text-primary)] outline-none"
              />

              <div className="flex items-center justify-between gap-2">
                {/* 5 Gold Stars with micro-overshoot pop */}
                <div className="flex items-center gap-[3px]">
                  {[1, 2, 3, 4, 5].map((star) => {
                    const filled = star <= targetAsset.rating;
                    const isPeakStar = star === targetAsset.rating;
                    return (
                      <button
                        key={star}
                        type="button"
                        aria-label={`评为 ${star} 星`}
                        onClick={() => {
                          const nextRating = targetAsset.rating === star ? 0 : star;
                          void updateAssets(
                            { assetIDs: [targetAsset.id], rating: nextRating },
                            destination,
                          );
                        }}
                        className={[
                          'charkle-pressable h-5 w-5 inline-flex items-center justify-center rounded-[var(--win-radius-control)] cursor-pointer',
                          filled
                            ? 'text-[#E5B243]'
                            : 'text-[var(--text-tertiary)]/55 hover:text-[var(--text-secondary)]',
                          isPeakStar ? 'charkle-micro-pop' : '',
                        ].join(' ')}
                      >
                        {filled ? (
                          <Star16Filled className="w-3.5 h-3.5" />
                        ) : (
                          <Star16Regular className="w-3.5 h-3.5" />
                        )}
                      </button>
                    );
                  })}
                </div>

                {!targetAsset.isTrashed && (
                  <button
                    type="button"
                    onClick={() => {
                      const nextPinned = !targetAsset.pinnedOffline;
                      void updateAssets(
                        { assetIDs: [targetAsset.id], pinnedOffline: nextPinned },
                        destination,
                      ).then(() => {
                        pushToast({
                          message: nextPinned
                            ? '已设为始终保留在本地'
                            : '已取消始终保留，将按需管理空间',
                          tone: 'info',
                        });
                      });
                    }}
                    title={
                      targetAsset.pinnedOffline
                        ? '已始终保留在本机，离线可用；点击取消'
                        : '始终将原文件保留在本机，不会被缓存自动清理'
                    }
                    className={[
                      'charkle-pressable inline-flex items-center gap-1 px-2 py-1 rounded-[var(--win-radius-control)] text-[10.5px] font-medium border cursor-pointer shrink-0',
                      targetAsset.pinnedOffline
                        ? 'bg-[var(--accent-soft)] text-[var(--accent)] border-[var(--accent-ring)]'
                        : 'bg-[var(--win-control-fill)] text-[var(--text-secondary)] border-[var(--win-stroke-control)] hover:bg-[var(--win-control-fill-hover)] hover:text-[var(--text-primary)]',
                    ].join(' ')}
                  >
                    <ArrowCircleDown16Regular className="w-3 h-3" />
                    <span>{targetAsset.pinnedOffline ? '已保留本地' : '保留在本地'}</span>
                  </button>
                )}
              </div>
            </div>
          </div>
        </InspectorSectionCard>
      );
    }

    if (section === 'quickActions') {
      const folderPath = targetAsset.folderID
        ? `当前所在：${getFolderDisplayPath(folders, targetAsset.folderID)}`
        : '当前所在：收件箱';
      const plainBookmark = isPlainWebBookmark(targetAsset);

      return (
        <InspectorSectionCard
          key="quickActions"
          cardId="quickActions"
          title={targetAsset.isTrashed ? '回收站操作' : '快捷操作'}
          icon={
            targetAsset.isTrashed ? (
              <Delete16Regular className="w-3.5 h-3.5" />
            ) : (
              <Flash16Regular className="w-3.5 h-3.5" />
            )
          }
          isDraggingSelf={isDraggingSelf}
          onStartHeaderDrag={handleStartHeaderDrag}
          onHeaderContextMenu={handleHeaderContextMenu}
        >
          {targetAsset.isTrashed ? (
            <div className="grid grid-cols-2 gap-2">
              <button
                type="button"
                onClick={() => {
                  const id = targetAsset.id;
                  void updateAssets(
                    { assetIDs: [id], isTrashed: false },
                    destination,
                  ).then(() => pushToast({ message: '已放回原处', tone: 'success' }));
                }}
                className="charkle-pressable h-8 px-2.5 rounded-[var(--win-radius-control)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-[var(--accent-text)] text-[11.5px] font-semibold inline-flex items-center justify-center gap-1.5 cursor-pointer"
              >
                <ArrowReset20Regular className="w-3.5 h-3.5" />
                <span>放回原处</span>
              </button>
              <button
                type="button"
                onClick={() => setPendingDeleteIds([targetAsset.id])}
                className="charkle-pressable h-8 px-2.5 rounded-[var(--win-radius-control)] bg-[var(--danger-soft)] hover:bg-[var(--danger)]/20 text-[var(--danger)] text-[11.5px] font-medium inline-flex items-center justify-center gap-1.5 cursor-pointer"
              >
                <Delete16Regular className="w-3.5 h-3.5" />
                <span>彻底删除</span>
              </button>
            </div>
          ) : (
            <div className="flex flex-col gap-2">
              {plainBookmark && targetAsset.sourceURL && (
                <div className="flex items-center gap-1.5">
                  <button
                    type="button"
                    onClick={() => {
                      if (!targetAsset.sourceURL) return;
                      const domain = formatBookmarkDomain(targetAsset);
                      void transport
                        .openExternalUrl(targetAsset.sourceURL)
                        .then(() => {
                          pushToast({
                            message: `已在默认浏览器中打开 ${domain}`,
                            tone: 'info',
                          });
                        })
                        .catch(() => {
                          pushToast({ message: '无法在默认浏览器中打开链接', tone: 'error' });
                        });
                      void markAssetOpened(targetAsset.id);
                    }}
                    className="charkle-pressable flex-1 min-w-0 h-[29px] px-2 rounded-[var(--win-radius-control)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-[var(--accent-text)] text-[11px] font-semibold inline-flex items-center justify-center gap-1 cursor-pointer"
                  >
                    <Open16Regular className="w-3 h-3 shrink-0" />
                    <span className="truncate">在默认浏览器中打开</span>
                  </button>
                  <button
                    type="button"
                    disabled={refreshingRichAssetId === targetAsset.id}
                    title="重新抓取网页标题与缩略图"
                    onClick={async () => {
                      const reqAssetId = targetAsset.id;
                      setRefreshingRichAssetId(reqAssetId);
                      try {
                        await refreshRichAsset(reqAssetId);
                        setPreviewFallbackThumb(false);
                        setPreviewLoadFailed(false);
                        setThumbBustNonce((n) => n + 1);
                      } catch (err) {
                        pushToast({
                          message: `刷新缩略图失败：${err instanceof Error ? err.message : String(err)}`,
                          tone: 'error',
                        });
                      } finally {
                        setRefreshingRichAssetId((cur) => (cur === reqAssetId ? null : cur));
                      }
                    }}
                    className="charkle-pressable win-control-elevation h-[29px] px-2 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11px] font-medium text-[var(--text-primary)] inline-flex items-center justify-center gap-1 disabled:opacity-50 cursor-pointer shrink-0"
                  >
                    <ArrowSync16Regular
                      className={`w-3 h-3 text-[var(--text-secondary)] shrink-0 ${
                        refreshingRichAssetId === targetAsset.id ? 'animate-spin' : ''
                      }`}
                    />
                    <span>刷新缩略图</span>
                  </button>
                </div>
              )}

              <div className="grid grid-cols-2 gap-2">
                <button
                  ref={boardBtnRef}
                  type="button"
                  onClick={() => setBoardMenuOpen((v) => !v)}
                  className="charkle-pressable win-control-elevation h-[29px] px-2 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11.5px] font-medium text-[var(--text-primary)] inline-flex items-center justify-center gap-1.5 cursor-pointer min-w-0"
                >
                  <CharkleIcon name="sparkle-board" style="duotone" size={14} />
                  <span className="truncate">加入情绪板</span>
                </button>

                <button
                  ref={folderBtnRef}
                  type="button"
                  title={folderPath}
                  onClick={() => setFolderMenuOpen((v) => !v)}
                  className="charkle-pressable win-control-elevation h-[29px] px-2 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11.5px] font-medium text-[var(--text-primary)] inline-flex items-center justify-center gap-1.5 cursor-pointer min-w-0"
                >
                  <Folder16Regular className="w-3.5 h-3.5 text-[var(--text-secondary)] shrink-0" />
                  <span className="truncate">{folderLabelFor(targetAsset.folderID)}</span>
                </button>
              </div>

              <div className="flex items-center gap-1.5">
                <button
                  type="button"
                  title="在文件资源管理器中显示"
                  onClick={() =>
                    void transport.revealInExplorer(targetAsset.id).catch(() => {
                      pushToast({ message: '无法定位本地文件', tone: 'error' });
                    })
                  }
                  className="charkle-pressable win-control-elevation flex-1 min-w-0 h-[27px] px-2 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11px] font-medium text-[var(--text-primary)] inline-flex items-center justify-center gap-1 cursor-pointer"
                >
                  <FolderOpen16Regular className="w-3 h-3 shrink-0 text-[var(--text-secondary)]" />
                  <span className="truncate">定位文件</span>
                </button>

                <button
                  type="button"
                  onClick={() =>
                    void transport
                      .copyAssetsToClipboard([targetAsset.id])
                      .then(() =>
                        pushToast({ message: '已拷贝到剪贴板', tone: 'success' }),
                      )
                      .catch((err) =>
                        pushToast({
                          message: err instanceof Error ? err.message : '无法拷贝该素材文件',
                          tone: 'error',
                        }),
                      )
                  }
                  className="charkle-pressable win-control-elevation h-[27px] px-2.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11px] font-medium text-[var(--text-primary)] inline-flex items-center gap-1 cursor-pointer shrink-0"
                >
                  <Copy16Regular className="w-3 h-3 text-[var(--text-secondary)]" />
                  <span>拷贝</span>
                </button>

                <button
                  type="button"
                  onClick={() =>
                    void cutAssets([targetAsset.id]).then(() =>
                      pushToast({
                        message: '已剪切，前往目标文件夹按 Ctrl+V 移动',
                        tone: 'info',
                      }),
                    )
                  }
                  className="charkle-pressable win-control-elevation h-[27px] px-2.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11px] font-medium text-[var(--text-primary)] inline-flex items-center gap-1 cursor-pointer shrink-0"
                >
                  <Cut16Regular className="w-3 h-3 text-[var(--text-secondary)]" />
                  <span>剪切</span>
                </button>
              </div>

              {/* Native Windows OLE drag-out handle */}
              <span
                role="button"
                tabIndex={0}
                title="按住鼠标左键拖出原文件到设计软件或资源管理器"
                onPointerDown={(e) => {
                  beginPointerDrag(
                    e,
                    {
                      kind: 'assets',
                      assetIds: [targetAsset.id],
                      previewAssetId: targetAsset.id,
                      title: targetAsset.title,
                    },
                    { forceOutboundOleOnDrag: true },
                  );
                }}
                className="charkle-pressable win-control-elevation h-[26px] px-2.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] inline-flex items-center justify-center gap-1.5 cursor-grab active:cursor-grabbing select-none"
              >
                <Share16Regular className="w-3 h-3" />
                <span>按住拖出到其他应用</span>
              </span>

              <button
                type="button"
                onClick={() => {
                  const id = targetAsset.id;
                  void updateAssets({ assetIDs: [id], isTrashed: true }, destination, {
                    undoMessage: '已移至回收站',
                    undoPatch: { assetIDs: [id], isTrashed: false },
                  });
                }}
                className="charkle-pressable w-full h-[27px] px-2.5 rounded-[var(--win-radius-control)] bg-[var(--danger-soft)] hover:bg-[var(--danger)]/20 text-[var(--danger)] text-[11px] font-medium inline-flex items-center justify-center gap-1.5 cursor-pointer"
              >
                <Delete16Regular className="w-3 h-3" />
                <span>移至回收站</span>
              </button>
            </div>
          )}
        </InspectorSectionCard>
      );
    }

    if (section === 'colorsAndTags') {
      const swatches = targetAsset.dominantColors.slice(0, 6);
      return (
        <InspectorSectionCard
          key="colorsAndTags"
          cardId="colorsAndTags"
          title="色板与标签"
          icon={<Color16Regular className="w-3.5 h-3.5" />}
          isDraggingSelf={isDraggingSelf}
          onStartHeaderDrag={handleStartHeaderDrag}
          onHeaderContextMenu={handleHeaderContextMenu}
        >
          <div className="flex flex-col gap-2.5">
            {swatches.length > 0 && (
              <>
                <div className="flex flex-col gap-1.5">
                  <span className="text-[10.5px] font-medium text-[var(--text-secondary)]">
                    提取色板
                  </span>
                  <div className="flex flex-wrap gap-1.5">
                    {swatches.map((swatch) => {
                      const hex = swatch.hex.toUpperCase();
                      return (
                        <button
                          key={hex}
                          type="button"
                          title="点击复制 HEX，右键按色彩筛选"
                          onClick={() => void copyText(hex, `已复制色值 ${hex}`)}
                          onContextMenu={(e) => {
                            e.preventDefault();
                            e.stopPropagation();
                            setSwatchMenu({ hex, point: { x: e.clientX, y: e.clientY } });
                          }}
                          className="charkle-pressable win-control-elevation inline-flex items-center gap-[5px] px-[7px] py-[4px] rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] cursor-pointer"
                        >
                          <span
                            className="w-[13px] h-[13px] rounded-[3px] border border-black/15 dark:border-white/15 shrink-0"
                            style={{ backgroundColor: hex }}
                          />
                          <span className="text-[10px] font-medium charkle-mono text-[var(--text-primary)]">
                            {hex}
                          </span>
                        </button>
                      );
                    })}
                  </div>
                </div>
                <InspectorInnerDivider />
              </>
            )}

            <div className="flex flex-col gap-[7px]">
              <span className="text-[10.5px] font-medium text-[var(--text-secondary)]">标签</span>

              {targetAsset.tags.length > 0 && (
                <div className="flex flex-wrap gap-1.5">
                  {targetAsset.tags.map((tag) => (
                    <span
                      key={tag}
                      className="inline-flex items-center gap-1 px-2 py-[3.5px] rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)]/75 border border-[var(--win-stroke-control)] text-[11px] font-medium text-[var(--text-primary)]"
                    >
                      <span>#{tag}</span>
                      <button
                        type="button"
                        aria-label={`移除标签 ${tag}`}
                        onClick={() =>
                          void updateAssets(
                            { assetIDs: [targetAsset.id], removeTags: [tag] },
                            destination,
                          )
                        }
                        className="text-[var(--text-tertiary)] hover:text-[var(--danger)] cursor-pointer inline-flex items-center"
                      >
                        <Dismiss16Regular className="w-2.5 h-2.5" />
                      </button>
                    </span>
                  ))}
                </div>
              )}

              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  const parsed = parseTagInput(newTagDraft);
                  if (parsed.length === 0) return;
                  setNewTagDraft('');
                  void updateAssets({ assetIDs: [targetAsset.id], addTags: parsed }, destination);
                }}
                className="win-input-elevation flex items-center gap-1.5 px-2 h-[29px] rounded-[var(--win-radius-control)] bg-[var(--bg-inspector-field)]"
              >
                <NumberSymbol16Regular className="w-3 h-3 text-[var(--text-tertiary)] shrink-0" />
                <input
                  type="text"
                  value={newTagDraft}
                  onChange={(e) => setNewTagDraft(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' && (e.nativeEvent.isComposing || e.keyCode === 229)) {
                      e.preventDefault();
                    }
                  }}
                  placeholder="添加标签，回车确认…"
                  aria-label="添加标签"
                  className="flex-1 min-w-0 bg-transparent text-[11.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
                />
              </form>

              {targetAsset.suggestedTags.length > 0 && (
                <div className="pt-0.5 flex flex-col gap-1.5">
                  <div className="flex items-center gap-2">
                    <span className="text-[10.5px] font-semibold text-[var(--text-secondary)]">
                      AI 建议标签
                    </span>
                    <span className="flex-1" />
                    <button
                      type="button"
                      title="忽略并清空当前未采纳的建议标签"
                      onClick={() => {
                        void updateAssets(
                          {
                            assetIDs: [targetAsset.id],
                            dismissSuggestedTags: [...targetAsset.suggestedTags],
                          },
                          destination,
                        ).then(() =>
                          pushToast({ message: '已清空未采纳的建议标签', tone: 'info' }),
                        );
                      }}
                      className="text-[10.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                    >
                      清空
                    </button>
                    <button
                      type="button"
                      onClick={() =>
                        void updateAssets(
                          { assetIDs: [targetAsset.id], acceptSuggestedTags: true },
                          destination,
                        )
                      }
                      className="text-[10.5px] font-medium text-[var(--accent)] hover:underline cursor-pointer"
                    >
                      全部采纳
                    </button>
                  </div>
                  <div className="flex flex-wrap gap-[5px]">
                    {targetAsset.suggestedTags.map((tag) => (
                      <button
                        key={tag}
                        type="button"
                        title="点击采纳标签，右键可忽略此建议"
                        onClick={() =>
                          void updateAssets(
                            {
                              assetIDs: [targetAsset.id],
                              addTags: [tag],
                              dismissSuggestedTags: [tag],
                            },
                            destination,
                          )
                        }
                        onContextMenu={(e) => {
                          e.preventDefault();
                          e.stopPropagation();
                          setSuggestedTagMenu({ tag, point: { x: e.clientX, y: e.clientY } });
                        }}
                        className="charkle-pressable inline-flex items-center gap-[3px] px-2 py-[3.5px] rounded-[var(--win-radius-control)] bg-[var(--accent-soft)] hover:bg-[var(--accent)]/20 text-[11px] font-medium text-[var(--accent)] cursor-pointer"
                      >
                        <span>+</span>
                        <span>{tag}</span>
                      </button>
                    ))}
                  </div>
                </div>
              )}
            </div>
          </div>
        </InspectorSectionCard>
      );
    }

    if (section === 'notesAndOCR') {
      const canRunOcr =
        targetAsset.mediaKind === 'image' ||
        targetAsset.mediaKind === 'animatedImage' ||
        targetAsset.mediaKind === 'designFile';

      return (
        <InspectorSectionCard
          key="notesAndOCR"
          cardId="notesAndOCR"
          title="备注与识别文本"
          icon={<DocumentText16Regular className="w-3.5 h-3.5" />}
          trailing={
            canRunOcr ? (
              <button
                type="button"
                disabled={runningOcrAssetId === targetAsset.id}
                aria-label="提取文字"
                onClick={async () => {
                  const reqAssetId = targetAsset.id;
                  setRunningOcrAssetId(reqAssetId);
                  try {
                    const updated = await transport.runAssetOcr(reqAssetId);
                    if (updated) {
                      patchSingleAssetInMemory(updated);
                      pushToast({
                        message: updated.ocrText
                          ? '已提取画面文字并建立索引'
                          : '未在画面中检测到文字',
                        tone: 'info',
                      });
                    }
                  } catch (err) {
                    pushToast({
                      message: `文字识别失败：${err instanceof Error ? err.message : String(err)}`,
                      tone: 'error',
                    });
                  } finally {
                    setRunningOcrAssetId((cur) => (cur === reqAssetId ? null : cur));
                  }
                }}
                className="charkle-pressable inline-flex items-center gap-1 text-[10.5px] font-medium text-[var(--accent)] hover:underline disabled:opacity-50 cursor-pointer"
              >
                <ScanText16Regular className="w-3 h-3" />
                <span>
                  {runningOcrAssetId === targetAsset.id
                    ? '识别中…'
                    : targetAsset.ocrText
                      ? '重新识别'
                      : '提取文字'}
                </span>
              </button>
            ) : undefined
          }
          isDraggingSelf={isDraggingSelf}
          onStartHeaderDrag={handleStartHeaderDrag}
          onHeaderContextMenu={handleHeaderContextMenu}
        >
          <div className="flex flex-col gap-2">
            <textarea
              rows={3}
              value={notesDraft}
              aria-label="素材备注"
              placeholder="添加灵感备注、构图笔记或来源说明…"
              onChange={(e) => handleNotesChange(targetAsset, e.target.value)}
              onBlur={() => flushNotesNow(targetAsset)}
              className="win-input-elevation w-full min-h-[64px] max-h-[120px] px-2.5 py-2 rounded-[var(--win-radius-control)] bg-[var(--bg-inspector-field)] text-[11.5px] leading-relaxed text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none resize-y charkle-scroll"
            />

            {targetAsset.ocrText && (
              <div className="p-2 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)]/55 flex flex-col gap-1">
                <div className="flex items-center justify-between gap-2">
                  <span className="text-[10.5px] font-semibold text-[var(--text-secondary)]">
                    OCR 识别文字
                  </span>
                  <button
                    type="button"
                    onClick={() => void copyText(targetAsset.ocrText!, '已复制识别文字')}
                    className="text-[10px] font-medium text-[var(--accent)] hover:underline cursor-pointer"
                  >
                    复制
                  </button>
                </div>
                <p className="text-[11px] leading-relaxed text-[var(--text-secondary)] select-text whitespace-pre-wrap charkle-wrap-safe max-h-[112px] overflow-y-auto charkle-scroll">
                  {targetAsset.ocrText}
                </p>
              </div>
            )}

            {targetAsset.aiDescription && (
              <p className="p-2 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)]/55 text-[11px] leading-relaxed text-[var(--text-secondary)] select-text charkle-wrap-safe">
                {targetAsset.aiDescription}
              </p>
            )}
          </div>
        </InspectorSectionCard>
      );
    }

    if (section === 'aiGeneration') {
      const aiGen = targetAsset.richMetadata?.aiGeneration;
      if (!aiGen || !hasMeaningfulAIGeneration(aiGen)) return null;

      const specItems: Array<{ key: string; label: string; node: React.ReactNode }> = [];
      if (aiGen.modelName) {
        specItems.push({
          key: 'model',
          label: '模型',
          node: aiGen.modelHash ? `${aiGen.modelName} (${aiGen.modelHash})` : aiGen.modelName,
        });
      }
      if (aiGen.sampler) {
        specItems.push({
          key: 'sampler',
          label: '采样器',
          node: aiGen.scheduler ? `${aiGen.sampler} / ${aiGen.scheduler}` : aiGen.sampler,
        });
      }
      if (aiGen.steps != null || aiGen.cfgScale != null) {
        const parts = [
          aiGen.steps != null ? `${aiGen.steps} 步` : null,
          aiGen.cfgScale != null
            ? `CFG ${aiGen.cfgScale.toFixed(1).replace(/\.0$/, '')}`
            : null,
        ].filter(Boolean);
        specItems.push({ key: 'stepsCfg', label: '步数 / CFG', node: parts.join(' · ') });
      }
      if (aiGen.seed) {
        specItems.push({
          key: 'seed',
          label: '随机种子',
          node: (
            <button
              type="button"
              title="点击复制 Seed"
              onClick={() => void copyText(aiGen.seed!, `已复制 Seed：${aiGen.seed}`)}
              className="inline-flex items-center gap-1 charkle-mono hover:text-[var(--accent)] cursor-pointer"
            >
              <span>{aiGen.seed}</span>
              <Copy16Regular className="w-2.5 h-2.5 text-[var(--text-tertiary)]" />
            </button>
          ),
        });
      }
      if (aiGen.sizeText) {
        specItems.push({ key: 'size', label: '生成尺寸', node: aiGen.sizeText });
      }
      if (aiGen.clipSkip != null) {
        specItems.push({ key: 'clipSkip', label: 'Clip Skip', node: String(aiGen.clipSkip) });
      }

      return (
        <InspectorSectionCard
          key="aiGeneration"
          cardId="aiGeneration"
          title="AI 生图信息"
          icon={<Sparkle16Regular className="w-3.5 h-3.5" />}
          trailing={
            aiGen.generator ? (
              <span className="px-2 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--accent-soft)] text-[var(--accent)] text-[9.5px] font-semibold max-w-[110px] truncate">
                {aiGen.generator}
              </span>
            ) : undefined
          }
          isDraggingSelf={isDraggingSelf}
          onStartHeaderDrag={handleStartHeaderDrag}
          onHeaderContextMenu={handleHeaderContextMenu}
        >
          <div className="flex flex-col gap-2">
            {aiGen.prompt && (
              <div className="flex flex-col gap-1">
                <div className="flex items-center justify-between">
                  <span className="text-[10.5px] font-semibold text-[var(--text-secondary)]">
                    正向提示词 (Prompt)
                  </span>
                  <button
                    type="button"
                    onClick={() => void copyText(aiGen.prompt!, '已复制正向 Prompt')}
                    className="inline-flex items-center gap-1 text-[10px] font-medium text-[var(--accent)] hover:underline cursor-pointer"
                  >
                    <Copy16Regular className="w-2.5 h-2.5" />
                    <span>复制</span>
                  </button>
                </div>
                <p className="p-2 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)]/55 text-[11px] leading-[1.55] text-[var(--text-primary)]/90 select-text charkle-wrap-safe max-h-[128px] overflow-y-auto charkle-scroll">
                  {aiGen.prompt}
                </p>
              </div>
            )}

            {aiGen.negativePrompt && (
              <div className="flex flex-col gap-1">
                <div className="flex items-center justify-between">
                  <span className="text-[10.5px] font-semibold text-[var(--text-secondary)]">
                    负向提示词 (Negative)
                  </span>
                  <button
                    type="button"
                    onClick={() => void copyText(aiGen.negativePrompt!, '已复制负向 Prompt')}
                    className="inline-flex items-center gap-1 text-[10px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                  >
                    <Copy16Regular className="w-2.5 h-2.5" />
                    <span>复制</span>
                  </button>
                </div>
                <p className="p-2 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)]/55 text-[10.5px] leading-[1.5] text-[var(--text-secondary)] select-text charkle-wrap-safe max-h-[92px] overflow-y-auto charkle-scroll">
                  {aiGen.negativePrompt}
                </p>
              </div>
            )}

            {specItems.length > 0 && (
              <div className="flex flex-col">
                {specItems.map((item, idx) => (
                  <React.Fragment key={item.key}>
                    {idx > 0 && <InspectorRowDivider />}
                    <SpecRow label={item.label} value={item.node} />
                  </React.Fragment>
                ))}
              </div>
            )}

            {aiGen.loras.length > 0 && (
              <div className="flex flex-col gap-1">
                <span className="text-[10.5px] font-medium text-[var(--text-secondary)]">
                  LoRA
                </span>
                <div className="flex flex-wrap gap-1">
                  {aiGen.loras.map((lora) => (
                    <span
                      key={lora}
                      className="px-2 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)] text-[10.5px] font-medium charkle-mono text-[var(--text-primary)]/85"
                    >
                      {lora}
                    </span>
                  ))}
                </div>
              </div>
            )}

            {aiGen.rawParameters && (
              <button
                type="button"
                onClick={() => void copyText(aiGen.rawParameters!, '已复制完整生图参数')}
                className="charkle-pressable win-control-elevation w-full py-1.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11px] font-medium text-[var(--text-primary)] inline-flex items-center justify-center gap-1.5 cursor-pointer"
              >
                <LayerDiagonal16Regular className="w-3 h-3 text-[var(--text-secondary)]" />
                <span>复制完整生图参数</span>
              </button>
            )}
          </div>
        </InspectorSectionCard>
      );
    }

    if (section === 'photoExif') {
      const exif = targetAsset.richMetadata?.photoExif;
      if (!exif || !hasMeaningfulCameraExif(exif)) return null;
      const summary = formatExposureSummary(exif);

      const rows: Array<[string, string]> = [];
      const cam = formatCameraName(exif);
      if (cam) rows.push(['相机', cam]);
      if (exif.lensModel) rows.push(['镜头', exif.lensModel]);
      if (exif.capturedAt) rows.push(['拍摄时间', exif.capturedAt]);
      const focal = formatFocalLength(exif);
      if (focal) rows.push(['焦距', focal]);
      const ap = formatAperture(exif.fNumber);
      if (ap) rows.push(['光圈', ap]);
      if (exif.exposureTime) rows.push(['快门', exif.exposureTime]);
      if (exif.iso != null && exif.iso > 0) rows.push(['ISO', String(exif.iso)]);
      if (exif.exposureBiasEV != null && Math.abs(exif.exposureBiasEV) > 0.01) {
        const sign = exif.exposureBiasEV > 0 ? '+' : '';
        rows.push(['曝光补偿', `${sign}${exif.exposureBiasEV.toFixed(1)} EV`]);
      }
      if (exif.meteringMode) rows.push(['测光模式', exif.meteringMode]);
      if (exif.whiteBalance) rows.push(['白平衡', exif.whiteBalance]);
      if (exif.flashFired != null) rows.push(['闪光灯', exif.flashFired ? '已闪光' : '未闪光']);
      if (exif.colorProfile) rows.push(['色彩空间', exif.colorProfile]);
      if (exif.bitDepth != null || exif.dpiWidth != null) {
        const parts = [
          exif.bitDepth != null ? `${exif.bitDepth}-bit` : null,
          exif.dpiWidth != null ? `${Math.round(exif.dpiWidth)} DPI` : null,
        ].filter(Boolean);
        if (parts.length > 0) rows.push(['色深 / 分辨率', parts.join(' · ')]);
      }
      if (exif.software) rows.push(['软件', exif.software]);
      if (exif.artist) rows.push(['作者', exif.artist]);
      if (exif.copyright) rows.push(['版权', exif.copyright]);

      const hasCoords = exif.latitude != null && exif.longitude != null;
      const coordText = hasCoords
        ? `${exif.latitude!.toFixed(5)}, ${exif.longitude!.toFixed(5)}`
        : null;

      return (
        <InspectorSectionCard
          key="photoExif"
          cardId="photoExif"
          title="拍摄参数 (EXIF)"
          icon={<Camera16Regular className="w-3.5 h-3.5" />}
          isDraggingSelf={isDraggingSelf}
          onStartHeaderDrag={handleStartHeaderDrag}
          onHeaderContextMenu={handleHeaderContextMenu}
        >
          <div className="flex flex-col gap-2">
            {summary && (
              <div className="w-full py-[6.5px] px-2 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)]/55 text-center text-[11.5px] font-semibold charkle-mono charkle-tabular text-[var(--text-primary)]">
                {summary}
              </div>
            )}

            <div className="flex flex-col">
              {rows.map(([label, val], idx) => (
                <React.Fragment key={label}>
                  {idx > 0 && <InspectorRowDivider />}
                  <SpecRow label={label} value={val} />
                </React.Fragment>
              ))}

              {hasCoords && coordText && (
                <>
                  {rows.length > 0 && <InspectorRowDivider />}
                  <div className="flex items-center justify-between gap-2 py-[5px] text-[11px]">
                    <span className="text-[var(--text-secondary)] shrink-0">拍摄位置</span>
                    <button
                      type="button"
                      title="在地图中查看拍摄位置"
                      onClick={() =>
                        void transport
                          .openExternalUrl(
                            `https://www.openstreetmap.org/?mlat=${exif.latitude}&mlon=${exif.longitude}#map=15/${exif.latitude}/${exif.longitude}`,
                          )
                          .catch(() => {
                            pushToast({ message: '无法在默认浏览器中打开地图链接', tone: 'error' });
                          })
                      }
                      className="inline-flex items-center gap-1 text-[10.5px] font-medium charkle-mono text-[var(--accent)] hover:underline cursor-pointer"
                    >
                      <Location16Regular className="w-3 h-3" />
                      <span>{coordText}</span>
                    </button>
                  </div>
                </>
              )}
            </div>
          </div>
        </InspectorSectionCard>
      );
    }

    if (section === 'mediaSpecs') {
      const exif = targetAsset.richMetadata?.photoExif;
      const showBasicColorSpecs = Boolean(exif && !hasMeaningfulCameraExif(exif));
      const depthDpi =
        showBasicColorSpecs && (exif?.bitDepth != null || exif?.dpiWidth != null)
          ? [
              exif?.bitDepth != null ? `${exif.bitDepth}-bit` : null,
              exif?.dpiWidth != null ? `${Math.round(exif.dpiWidth)} DPI` : null,
            ]
              .filter(Boolean)
              .join(' · ')
          : '';
      const canRefreshRich = Boolean(
        targetAsset.sourceURL &&
          (targetAsset.richMetadata?.githubRepo ||
            targetAsset.richMetadata?.socialPost ||
            targetAsset.mediaKind === 'webBookmark'),
      );

      let sourceHost = targetAsset.sourceDomain ?? '';
      if (!sourceHost && targetAsset.sourceURL) {
        try {
          sourceHost = new URL(targetAsset.sourceURL).host;
        } catch {
          sourceHost = '打开链接';
        }
      }

      return (
        <InspectorSectionCard
          key="mediaSpecs"
          cardId="mediaSpecs"
          title="媒体信息"
          icon={<Info16Regular className="w-3.5 h-3.5" />}
          trailing={
            canRefreshRich ? (
              <button
                type="button"
                disabled={refreshingRichAssetId === targetAsset.id}
                title="刷新富媒体元数据"
                onClick={async () => {
                  const reqAssetId = targetAsset.id;
                  setRefreshingRichAssetId(reqAssetId);
                  try {
                    await refreshRichAsset(reqAssetId);
                    setPreviewFallbackThumb(false);
                    setPreviewLoadFailed(false);
                    setThumbBustNonce((n) => n + 1);
                  } catch (err) {
                    pushToast({
                      message: `刷新元数据失败：${err instanceof Error ? err.message : String(err)}`,
                      tone: 'error',
                    });
                  } finally {
                    setRefreshingRichAssetId((cur) => (cur === reqAssetId ? null : cur));
                  }
                }}
                className="charkle-pressable inline-flex items-center gap-1 text-[10.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--accent)] disabled:opacity-50 cursor-pointer"
              >
                <ArrowSync16Regular
                  className={`w-3 h-3 ${
                    refreshingRichAssetId === targetAsset.id ? 'animate-spin' : ''
                  }`}
                />
                <span>刷新</span>
              </button>
            ) : undefined
          }
          isDraggingSelf={isDraggingSelf}
          onStartHeaderDrag={handleStartHeaderDrag}
          onHeaderContextMenu={handleHeaderContextMenu}
        >
          <div className="flex flex-col">
            <SpecRow label="类型" value={displayTypeLabel(targetAsset)} />

            {targetAsset.pixelWidth > 0 && targetAsset.pixelHeight > 0 && (
              <>
                <InspectorRowDivider />
                <SpecRow
                  label="尺寸"
                  value={`${targetAsset.pixelWidth} × ${targetAsset.pixelHeight} (${aspectShapeLabel(
                    targetAsset.pixelWidth,
                    targetAsset.pixelHeight,
                  )})`}
                />
              </>
            )}

            <InspectorRowDivider />
            <SpecRow label="大小" value={formatBytes(targetAsset.fileSizeBytes)} />

            {targetAsset.durationSeconds != null && targetAsset.durationSeconds > 0 && (
              <>
                <InspectorRowDivider />
                <SpecRow label="时长" value={formatDuration(targetAsset.durationSeconds)} />
              </>
            )}

            {showBasicColorSpecs && exif?.colorProfile && (
              <>
                <InspectorRowDivider />
                <SpecRow label="色彩空间" value={exif.colorProfile} />
              </>
            )}

            {depthDpi && (
              <>
                <InspectorRowDivider />
                <SpecRow label="色深 / 分辨率" value={depthDpi} />
              </>
            )}

            <InspectorRowDivider />
            <SpecRow
              label="原文件状态"
              value={targetAsset.isLocalOriginalCached ? '已缓存本地' : '云端按需拉取'}
            />

            {targetAsset.sourceURL && (
              <>
                <InspectorRowDivider />
                <div className="flex items-center justify-between gap-2 py-[5px] text-[11px]">
                  <span className="text-[var(--text-secondary)] shrink-0">来源</span>
                  <button
                    type="button"
                    onClick={() =>
                      void transport.openExternalUrl(targetAsset.sourceURL!).catch(() => {
                        pushToast({ message: '无法在默认浏览器中打开链接', tone: 'error' });
                      })
                    }
                    className="inline-flex items-center gap-1 font-medium text-[var(--accent)] hover:underline truncate min-w-0 cursor-pointer"
                  >
                    <span className="truncate">{sourceHost || '打开链接'}</span>
                    <Open16Regular className="w-2.5 h-2.5 shrink-0" />
                  </button>
                </div>
              </>
            )}
          </div>
        </InspectorSectionCard>
      );
    }

    if (section === 'githubRepo') {
      const repo = targetAsset.richMetadata?.githubRepo;
      if (!repo) return null;

      return (
        <InspectorSectionCard
          key="githubRepo"
          cardId="githubRepo"
          title="GitHub 仓库信息"
          icon={<Code16Regular className="w-3.5 h-3.5" />}
          isDraggingSelf={isDraggingSelf}
          onStartHeaderDrag={handleStartHeaderDrag}
          onHeaderContextMenu={handleHeaderContextMenu}
        >
          <div className="flex flex-col gap-2">
            <div className="flex items-center gap-2.5 text-[11.5px] charkle-tabular">
              <span className="font-semibold text-[var(--text-primary)]">
                ★ {repo.stars.toLocaleString()}
              </span>
              <span className="font-medium text-[var(--text-secondary)]">
                ⑂ {repo.forks.toLocaleString()}
              </span>
              {repo.language && (
                <span className="text-[11px] font-medium text-[var(--text-secondary)] truncate">
                  {repo.language}
                </span>
              )}
            </div>

            <button
              type="button"
              onClick={() => openQuickLook(targetAsset.id, null)}
              className="charkle-pressable w-full py-1.5 px-2.5 rounded-[var(--win-radius-control)] bg-[var(--accent-soft)] hover:bg-[var(--accent)]/20 text-[var(--accent)] text-[11.5px] font-semibold inline-flex items-center justify-center gap-1.5 cursor-pointer"
            >
              <DocumentText16Regular className="w-3.5 h-3.5" />
              <span>在应用内阅读完整 README</span>
            </button>
          </div>
        </InspectorSectionCard>
      );
    }

    if (section === 'socialMediaExtract') {
      const post = targetAsset.richMetadata?.socialPost;
      const attachments = getEffectiveSocialAttachments(post);
      if (!post || attachments.length === 0) return null;

      const inTauri = isTauriRuntime();
      const isXhs = post.platform === 'xiaohongshu';
      const postNoun = isXhs ? '笔记' : '推文';
      const platformLabel =
        post.platform === 'xiaohongshu'
          ? '小红书'
          : post.platform === 'threads'
            ? 'Threads'
            : post.platform === 'bluesky'
              ? 'Bluesky'
              : 'X';
      const platformBg =
        post.platform === 'xiaohongshu'
          ? '#FF2442'
          : post.platform === 'bluesky'
            ? '#0284C7'
            : post.platform === 'threads'
              ? '#27272A'
              : '#18181B';
      const avatarSrc = resolveSocialMediaUrl(post.authorAvatarURL, inTauri);
      const displayHandle = formatSocialDisplayHandle(post);

      const handleExtractOne = async (att: SocialMediaAttachment, idx: number) => {
        const key = `${att.id}-${idx}`;
        setExtractingKey(key);
        try {
          const created = await extractSocialAttachment(targetAsset, att, idx, destination);
          if (created) {
            pushToast({
              message: `已单独提取「${created.title}」并保留${postNoun}来源`,
              tone: 'success',
            });
          }
        } catch (err) {
          pushToast({
            message: `提取${postNoun}媒体失败：${err instanceof Error ? err.message : String(err)}`,
            tone: 'error',
          });
        } finally {
          setExtractingKey(null);
        }
      };

      const handleExtractAll = async () => {
        setExtractingKey('__all__');
        try {
          const created = await extractAllSocialAttachments(targetAsset, destination);
          if (created.length > 0) {
            pushToast({
              message: `已全部提取 ${created.length} 项${postNoun}媒体`,
              tone: 'success',
            });
          }
        } catch (err) {
          pushToast({
            message: `批量提取失败：${err instanceof Error ? err.message : String(err)}`,
            tone: 'error',
          });
        } finally {
          setExtractingKey(null);
        }
      };

      return (
        <InspectorSectionCard
          key="socialMediaExtract"
          cardId="socialMediaExtract"
          title={isXhs ? '笔记媒体提取' : '推文媒体提取'}
          icon={<ImageMultiple16Regular className="w-3.5 h-3.5" />}
          trailing={
            <div className="inline-flex items-center gap-1.5">
              <span
                style={{ backgroundColor: platformBg }}
                className="px-1.5 py-[1px] rounded-[var(--win-radius-control)] text-[9.5px] font-semibold text-white"
              >
                {platformLabel}
              </span>
              <span className="text-[10px] font-medium text-[var(--text-tertiary)] charkle-tabular">
                {attachments.length} 项
              </span>
            </div>
          }
          isDraggingSelf={isDraggingSelf}
          onStartHeaderDrag={handleStartHeaderDrag}
          onHeaderContextMenu={handleHeaderContextMenu}
        >
          <div className="flex flex-col gap-2">
            <div className="flex items-center gap-2 min-w-0">
              {avatarSrc && !socialAvatarFailed ? (
                <img
                  src={avatarSrc}
                  alt={post.authorName}
                  referrerPolicy="no-referrer"
                  onError={() => setSocialAvatarFailed(true)}
                  className="h-5 w-5 rounded-full object-cover bg-[var(--bg-subtle)] shrink-0"
                />
              ) : (
                <span
                  style={{ backgroundColor: platformBg }}
                  className="h-5 w-5 rounded-full text-white text-[10px] font-bold inline-flex items-center justify-center shrink-0"
                >
                  {(post.authorName || platformLabel).slice(0, 1).toUpperCase()}
                </span>
              )}
              <span className="text-[11.5px] font-medium text-[var(--text-primary)] truncate">
                {post.authorName}
              </span>
              {displayHandle && (
                <span className="text-[10.5px] text-[var(--text-tertiary)] truncate">
                  {displayHandle}
                </span>
              )}
            </div>

            <p className="text-[11px] leading-relaxed text-[var(--text-secondary)]">
              可将{postNoun}里的图片或视频单独存为素材，并自动保留原{postNoun}作者、正文与链接。
            </p>

            {attachments.length > 1 && (
              <button
                type="button"
                disabled={extractingKey !== null}
                onClick={() => void handleExtractAll()}
                className="charkle-pressable w-full px-2.5 py-1.5 rounded-[var(--win-radius-control)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-[var(--accent-text)] text-[11.5px] font-semibold inline-flex items-center gap-1.5 disabled:opacity-60 cursor-pointer"
              >
                <ImageMultiple16Regular className="w-3.5 h-3.5" />
                <span>
                  {extractingKey === '__all__'
                    ? '正在提取全部媒体…'
                    : `全部提取为独立素材（${attachments.length} 项）`}
                </span>
              </button>
            )}

            {attachments.map((att, idx) => {
              const isVideoLike = att.kind === 'video' || att.kind === 'gif';
              const kindText =
                att.kind === 'video' ? '视频' : att.kind === 'gif' ? '动图' : '图片';
              const key = `${att.id}-${idx}`;
              const thumbPreview = resolveSocialMediaUrl(att.thumbnailURL || att.url, inTauri);
              return (
                <button
                  key={key}
                  type="button"
                  disabled={extractingKey !== null}
                  onClick={() => void handleExtractOne(att, idx)}
                  className="charkle-pressable w-full px-2 py-1.5 rounded-[var(--win-radius-control)] bg-[var(--accent-soft)] hover:bg-[var(--accent)]/20 text-[var(--accent)] text-[11.5px] font-medium inline-flex items-center gap-2 disabled:opacity-60 cursor-pointer"
                >
                  {thumbPreview && !isVideoLike && !failedSocialThumbKeys[key] ? (
                    <img
                      src={thumbPreview}
                      alt=""
                      referrerPolicy="no-referrer"
                      onError={() =>
                        setFailedSocialThumbKeys((prev) => ({ ...prev, [key]: true }))
                      }
                      className="h-5 w-5 rounded-[var(--win-radius-control)] object-cover bg-[var(--bg-subtle)] shrink-0"
                    />
                  ) : isVideoLike ? (
                    <Filmstrip16Regular className="w-3.5 h-3.5 shrink-0" />
                  ) : (
                    <Image16Regular className="w-3.5 h-3.5 shrink-0" />
                  )}
                  <span className="truncate">
                    {extractingKey === key
                      ? `正在提取第 ${idx + 1} 个${kindText}…`
                      : `提取第 ${idx + 1} 个${kindText}为独立素材`}
                  </span>
                </button>
              );
            })}
          </div>
        </InspectorSectionCard>
      );
    }

    return null;
  };

  // -------------------------------------------------------------------------
  // Multi-Select Batch Inspector (1:1 macOS 3-card layout)
  // -------------------------------------------------------------------------

  const renderMultiSelectBatchInspector = () => {
    const ids = selectedAssets.map((a) => a.id);
    const isTrashSelection =
      destination.type === 'trash' ||
      (selectedAssets.length > 0 && selectedAssets.every((a) => a.isTrashed));
    const allKeptLocally =
      selectedAssets.length > 0 && selectedAssets.every((a) => a.pinnedOffline);
    const assetsWithSuggestions = selectedAssets.filter((a) => a.suggestedTags.length > 0);
    const allSuggestionTags = Array.from(
      new Set(assetsWithSuggestions.flatMap((a) => a.suggestedTags)),
    );
    const batchTagCounts = new Map<string, number>();
    for (const item of selectedAssets) {
      for (const tag of item.tags) {
        batchTagCounts.set(tag, (batchTagCounts.get(tag) ?? 0) + 1);
      }
    }
    const batchExistingTags = Array.from(batchTagCounts.entries()).sort(
      (a, b) => b[1] - a[1] || a[0].localeCompare(b[0], 'zh-CN'),
    );

    return (
      <div className="flex flex-col gap-2.5 charkle-pane-fade">
        {/* Card 1: Selection Overview + Primary Action */}
        <section className="rounded-[var(--win-radius-card)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-card)] p-3 flex flex-col gap-2.5 shadow-[0_1px_2px_rgba(0,0,0,0.03)] dark:shadow-[0_1px_2px_rgba(0,0,0,0.2)]">
          <div className="flex flex-col gap-1">
            <div className="text-[14.5px] font-semibold text-[var(--text-primary)] charkle-tabular">
              已选中 {ids.length} 项素材
            </div>
            <p className="text-[11px] leading-relaxed text-[var(--text-secondary)]">
              {isTrashSelection
                ? '这些素材当前位于回收站，可恢复到原位置或彻底删除'
                : '批量归档、打标签或一键进入情绪板排版'}
            </p>
          </div>

          {isTrashSelection ? (
            <div className="flex flex-col gap-2">
              <button
                type="button"
                onClick={() => {
                  const restoreIds = [...ids];
                  useCoordinatorStore.getState().clearSelection();
                  void updateAssets({ assetIDs: restoreIds, isTrashed: false }, destination).then(
                    () =>
                      pushToast({
                        message: `已将 ${restoreIds.length} 项放回原处`,
                        tone: 'success',
                      }),
                  );
                }}
                className="charkle-pressable w-full px-2.5 py-2 rounded-[var(--win-radius-control)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-[var(--accent-text)] text-[12px] font-semibold inline-flex items-center gap-2 cursor-pointer"
              >
                <ArrowReset20Regular className="w-3.5 h-3.5" />
                <span>全部放回原处</span>
              </button>
              <button
                type="button"
                onClick={() => setPendingDeleteIds([...ids])}
                className="charkle-pressable w-full px-2.5 py-2 rounded-[var(--win-radius-control)] bg-[var(--danger-soft)] hover:bg-[var(--danger)]/20 text-[var(--danger)] text-[12px] font-medium inline-flex items-center gap-2 cursor-pointer"
              >
                <Delete16Regular className="w-3.5 h-3.5" />
                <span>彻底删除所选 {ids.length} 项</span>
              </button>
            </div>
          ) : (
            <button
              type="button"
              disabled={creatingBatchBoard}
              onClick={async () => {
                if (creatingBatchBoard) return;
                setCreatingBatchBoard(true);
                try {
                  const board = await createBoard(`灵感合集 (${ids.length})`, '', 'autoEditorial');
                  await addAssetsToBoard(board.id, ids);
                  setDestination({ type: 'moodboard', id: board.id });
                  await openBoard(board.id);
                } catch (err) {
                  pushToast({
                    message: `生成情绪板失败：${err instanceof Error ? err.message : String(err)}`,
                    tone: 'error',
                  });
                } finally {
                  setCreatingBatchBoard(false);
                }
              }}
              className="charkle-pressable w-full py-2 px-3 rounded-[var(--win-radius-control)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-[var(--accent-text)] text-[12px] font-semibold inline-flex items-center justify-center gap-1.5 disabled:opacity-60 cursor-pointer"
            >
              <Sparkle16Regular className="w-3.5 h-3.5" />
              <span>{creatingBatchBoard ? '正在生成情绪板…' : '从所选生成情绪板'}</span>
            </button>
          )}
        </section>

        {!isTrashSelection && (
          <>
            {/* Card 2: Bulk Organize */}
            <InspectorSectionCard
              title="批量整理"
              icon={<LayerDiagonal16Regular className="w-3.5 h-3.5" />}
            >
              <div className="flex flex-col gap-2.5">
                <div className="flex flex-col gap-1">
                  <span className="text-[10.5px] font-medium text-[var(--text-secondary)]">
                    移动到文件夹
                  </span>
                  <button
                    ref={batchFolderBtnRef}
                    type="button"
                    onClick={() => setBatchFolderMenuOpen((v) => !v)}
                    className="charkle-pressable win-control-elevation w-full h-[30px] px-2.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11.5px] font-medium text-[var(--text-primary)] inline-flex items-center gap-1.5 cursor-pointer"
                  >
                    <Folder16Regular className="w-3.5 h-3.5 text-[var(--text-secondary)] shrink-0" />
                    <span className="flex-1 text-left truncate">选择目标文件夹…</span>
                    <ChevronUpDown16Regular className="w-3 h-3 text-[var(--text-tertiary)] shrink-0" />
                  </button>
                </div>

                <InspectorInnerDivider />

                <div className="flex flex-col gap-1.5">
                  <span className="text-[10.5px] font-medium text-[var(--text-secondary)]">
                    批量标签
                  </span>
                  {batchExistingTags.length > 0 && (
                    <div className="flex flex-wrap gap-1.5">
                      {batchExistingTags.map(([tag, count]) => (
                        <span
                          key={tag}
                          className="inline-flex items-center gap-1 px-2 py-[3.5px] rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)]/75 border border-[var(--win-stroke-control)] text-[11px] font-medium text-[var(--text-primary)]"
                        >
                          <span>#{tag}</span>
                          {count < ids.length && (
                            <span className="text-[9.5px] text-[var(--text-tertiary)] charkle-tabular">
                              {count}/{ids.length}
                            </span>
                          )}
                          <button
                            type="button"
                            aria-label={`从所选移除标签 ${tag}`}
                            title={`从全部 ${ids.length} 项所选素材移除 #${tag}`}
                            onClick={() =>
                              void updateAssets(
                                { assetIDs: ids, removeTags: [tag] },
                                destination,
                              ).then(() =>
                                pushToast({
                                  message: `已从所选素材移除标签 #${tag}`,
                                  tone: 'info',
                                }),
                              )
                            }
                            className="text-[var(--text-tertiary)] hover:text-[var(--danger)] cursor-pointer inline-flex items-center"
                          >
                            <Dismiss16Regular className="w-2.5 h-2.5" />
                          </button>
                        </span>
                      ))}
                    </div>
                  )}
                  <form
                    onSubmit={(e) => {
                      e.preventDefault();
                      const parsed = parseTagInput(batchTagDraft);
                      if (parsed.length === 0) return;
                      setBatchTagDraft('');
                      void updateAssets({ assetIDs: ids, addTags: parsed }, destination).then(
                        () =>
                          pushToast({
                            message: `已为 ${ids.length} 项添加标签 #${parsed.join(' #')}`,
                            tone: 'success',
                          }),
                      );
                    }}
                    className="win-input-elevation flex items-center gap-1.5 px-2 h-[29px] rounded-[var(--win-radius-control)] bg-[var(--bg-inspector-field)]"
                  >
                    <NumberSymbol16Regular className="w-3 h-3 text-[var(--text-tertiary)] shrink-0" />
                    <input
                      type="text"
                      value={batchTagDraft}
                      onChange={(e) => setBatchTagDraft(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter' && (e.nativeEvent.isComposing || e.keyCode === 229)) {
                          e.preventDefault();
                        }
                      }}
                      placeholder="输入标签回车批量添加…"
                      aria-label="批量添加标签"
                      className="flex-1 min-w-0 bg-transparent text-[11.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
                    />
                  </form>

                  {assetsWithSuggestions.length > 0 && (
                    <div className="flex items-center justify-between gap-2 pt-0.5">
                      <button
                        type="button"
                        onClick={() => {
                          void updateAssets(
                            { assetIDs: ids, acceptSuggestedTags: true },
                            destination,
                          ).then(() =>
                            pushToast({ message: '已批量采纳 AI 建议标签', tone: 'success' }),
                          );
                        }}
                        className="text-[10.5px] font-medium text-[var(--accent)] hover:underline cursor-pointer"
                      >
                        采纳全部建议（{assetsWithSuggestions.length} 项）
                      </button>
                      <button
                        type="button"
                        onClick={() => {
                          void updateAssets(
                            { assetIDs: ids, dismissSuggestedTags: allSuggestionTags },
                            destination,
                          ).then(() =>
                            pushToast({
                              message: '已清空所选素材的未采纳建议标签',
                              tone: 'info',
                            }),
                          );
                        }}
                        className="text-[10.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                      >
                        清空建议
                      </button>
                    </div>
                  )}
                </div>

                <InspectorInnerDivider />

                <div className="flex flex-col gap-1.5">
                  <div className="flex items-center justify-between">
                    <span className="text-[10.5px] font-medium text-[var(--text-secondary)]">
                      批量评分
                    </span>
                    <button
                      type="button"
                      onClick={() =>
                        void updateAssets({ assetIDs: ids, rating: 0 }, destination)
                      }
                      className="text-[10.5px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                    >
                      清除评分
                    </button>
                  </div>
                  <div className="flex items-center gap-1.5">
                    {[1, 2, 3, 4, 5].map((star) => (
                      <button
                        key={star}
                        type="button"
                        aria-label={`批量评为 ${star} 星`}
                        onClick={() =>
                          void updateAssets({ assetIDs: ids, rating: star }, destination)
                        }
                        className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[#E5B243] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                      >
                        <Star16Filled className="w-3.5 h-3.5" />
                      </button>
                    ))}
                  </div>
                </div>
              </div>
            </InspectorSectionCard>

            {/* Card 3: Offline & Actions */}
            <InspectorSectionCard
              title="本地与操作"
              icon={<Options16Regular className="w-3.5 h-3.5" />}
            >
              <div className="flex flex-col gap-2">
                <button
                  type="button"
                  onClick={() => {
                    const nextPinned = !allKeptLocally;
                    void updateAssets(
                      { assetIDs: ids, pinnedOffline: nextPinned },
                      destination,
                    ).then(() =>
                      pushToast({
                        message: nextPinned
                          ? `已将 ${ids.length} 项设为始终保留在本地`
                          : `已取消 ${ids.length} 项的始终保留`,
                        tone: 'info',
                      }),
                    );
                  }}
                  className="charkle-pressable win-control-elevation w-full px-2.5 py-1.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11.5px] font-medium text-[var(--text-primary)] inline-flex items-center gap-2 cursor-pointer"
                >
                  <ArrowCircleDown16Regular className="w-3.5 h-3.5 text-[var(--text-secondary)]" />
                  <span>{allKeptLocally ? '取消全部保留在本地' : '全部始终保留在本地'}</span>
                </button>

                <div className="grid grid-cols-2 gap-1.5">
                  <button
                    type="button"
                    onClick={() =>
                      void transport
                        .copyAssetsToClipboard(ids)
                        .then((n) =>
                          pushToast({
                            message: `已拷贝 ${n} 项文件到剪贴板`,
                            tone: 'success',
                          }),
                        )
                        .catch((err) =>
                          pushToast({
                            message: err instanceof Error ? err.message : '无法拷贝素材文件',
                            tone: 'error',
                          }),
                        )
                    }
                    className="charkle-pressable win-control-elevation px-2.5 py-1.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11.5px] font-medium text-[var(--text-primary)] inline-flex items-center justify-center gap-1.5 cursor-pointer"
                  >
                    <Copy16Regular className="w-3.5 h-3.5 text-[var(--text-secondary)]" />
                    <span>拷贝文件</span>
                  </button>

                  <button
                    type="button"
                    onClick={() =>
                      void cutAssets(ids).then(() =>
                        pushToast({
                          message: `已剪切 ${ids.length} 项，前往目标文件夹按 Ctrl+V 移动`,
                          tone: 'info',
                        }),
                      )
                    }
                    className="charkle-pressable win-control-elevation px-2.5 py-1.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] hover:bg-[var(--win-control-fill-hover)] text-[11.5px] font-medium text-[var(--text-primary)] inline-flex items-center justify-center gap-1.5 cursor-pointer"
                  >
                    <Cut16Regular className="w-3.5 h-3.5 text-[var(--text-secondary)]" />
                    <span>剪切</span>
                  </button>
                </div>

                <button
                  type="button"
                  onClick={() => {
                    useCoordinatorStore.getState().clearSelection();
                    void updateAssets({ assetIDs: ids, isTrashed: true }, destination, {
                      undoMessage: `已将 ${ids.length} 项移至回收站`,
                      undoPatch: { assetIDs: ids, isTrashed: false },
                    });
                  }}
                  className="charkle-pressable w-full px-2.5 py-1.5 rounded-[var(--win-radius-control)] bg-[var(--danger-soft)] hover:bg-[var(--danger)]/20 text-[var(--danger)] text-[11.5px] font-medium inline-flex items-center gap-2 cursor-pointer"
                >
                  <Delete16Regular className="w-3.5 h-3.5" />
                  <span>移至回收站</span>
                </button>
              </div>
            </InspectorSectionCard>
          </>
        )}
      </div>
    );
  };

  // Context menu position helpers for card reorder menu
  const contextCardIdx = cardContextMenu
    ? visibleSections.indexOf(cardContextMenu.cardId)
    : -1;
  const contextCardIsFirst = contextCardIdx === 0;
  const contextCardIsLast =
    contextCardIdx !== -1 && contextCardIdx === visibleSections.length - 1;

  return (
    <aside
      aria-label="属性检查器"
      data-testid={isQuickLookHosted ? 'quicklook-inspector-view' : 'inspector-view'}
      className="relative w-full min-w-0 shrink-0 h-full bg-[var(--bg-inspector)] border-l border-[var(--win-stroke-divider)] flex flex-col overflow-hidden"
    >
      {/* Subtle top ambient tint ONLY for single asset */}
      {asset && (
        <div
          aria-hidden="true"
          style={ambientStyle}
          className="pointer-events-none absolute top-0 left-0 right-0 h-[200px] z-0"
        />
      )}

      {/* Top Synchronized Info | Similar Tab Switcher (1:1 macOS InspectorView.swift, 10px top inset) */}
      {asset && (
        <div className="relative z-10 shrink-0 px-3 pt-[10px] pb-2">
          <SegmentedControl<InspectorTab>
            value={inspectorTab}
            onChange={setInspectorTab}
            ariaLabel="检查器标签页"
            size="xs"
            className="w-full grid grid-cols-2"
            options={[
              { value: 'info', label: '信息' },
              {
                value: 'similar',
                label: similar.length > 0 ? `类似项目 (${similar.length})` : '类似项目',
              },
            ]}
          />
        </div>
      )}

      <div className="relative z-10 flex-1 min-h-0 overflow-y-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden px-3 py-2 flex flex-col gap-2.5">
        {selectedAssets.length === 0 ? (
          <div className="flex-1 flex flex-col items-center justify-center text-center gap-3 px-4 py-10">
            <EmptyStateVignette kind="emptyInspector" compact />
            <div>
              <div className="text-[13px] font-semibold text-[var(--text-secondary)]">
                选择素材查看详情
              </div>
              <p className="mt-1 text-[11.5px] leading-relaxed text-[var(--text-tertiary)] whitespace-pre-line">
                {'单击卡片检视色板与元数据\n框选多张可一键生成情绪板'}
              </p>
            </div>
          </div>
        ) : selectedAssets.length > 1 ? (
          renderMultiSelectBatchInspector()
        ) : asset && inspectorTab === 'similar' ? (
          /* Tab 2: Similar Assets Grid (1:1 macOS singleAssetSimilarTab) */
          <div className="flex flex-col gap-2.5 charkle-pane-fade">
            <div className="text-[11.5px] font-medium text-[var(--text-secondary)] truncate">
              与「{asset.title}」相似的素材
            </div>

            {showSimilarSkeleton ? (
              <InspectorSimilarSkeleton />
            ) : similar.length === 0 ? (
              <div className="flex flex-col items-center text-center gap-2.5 py-9 px-3">
                <EmptyStateVignette kind="noResults" compact />
                <div className="text-[12px] font-medium text-[var(--text-secondary)]">
                  暂无视觉或色彩相近的素材
                </div>
                <p className="text-[11px] text-[var(--text-tertiary)] leading-relaxed">
                  导入更多素材或等待本地视觉特征索引完成后，这里会自动呈现同风格相似项目。
                </p>
              </div>
            ) : (
              <div className="grid grid-cols-2 gap-2">
                {similar.map((scored) => {
                  const ratio = Math.max(
                    0.68,
                    Math.min(
                      1.5,
                      scored.asset.pixelHeight > 0
                        ? scored.asset.pixelWidth / scored.asset.pixelHeight
                        : 1,
                    ),
                  );
                  return (
                    <button
                      key={scored.asset.id}
                      type="button"
                      onPointerDown={(e) => {
                        beginPointerDrag(e, {
                          kind: 'assets',
                          assetIds: [scored.asset.id],
                          previewAssetId: scored.asset.id,
                          title: scored.asset.title,
                        });
                      }}
                      onClick={() => {
                        if (wasRecentPointerDrag()) return;
                        setSelection([scored.asset.id], scored.asset.id);
                        if (isQuickLookHosted && !isPlainWebBookmark(scored.asset)) {
                          openQuickLook(scored.asset.id, null);
                        }
                      }}
                      onDoubleClick={() => {
                        setSelection([scored.asset.id], scored.asset.id);
                        if (isPlainWebBookmark(scored.asset) && scored.asset.sourceURL) {
                          const domain = formatBookmarkDomain(scored.asset);
                          void transport
                            .openExternalUrl(scored.asset.sourceURL)
                            .then(() => {
                              pushToast({
                                message: `已在默认浏览器中打开 ${domain}`,
                                tone: 'info',
                              });
                            })
                            .catch(() => {
                              pushToast({ message: '无法在默认浏览器中打开链接', tone: 'error' });
                            });
                          void markAssetOpened(scored.asset.id);
                        } else {
                          openQuickLook(scored.asset.id, null);
                        }
                      }}
                      title={
                        scored.matchReasons.length > 0
                          ? `${scored.asset.title} · ${scored.matchReasons.join(' / ')}`
                          : scored.asset.title
                      }
                      style={{ aspectRatio: String(ratio) }}
                      className="group relative rounded-[var(--win-radius-card)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--win-stroke-card)] hover:border-[var(--accent)] cursor-pointer"
                    >
                      <img
                        src={withThumbCacheBust(
                          transport.thumbnailUrl(scored.asset.id, 'grid520'),
                          scored.asset.updatedAt,
                        )}
                        alt={scored.asset.title}
                        loading="lazy"
                        draggable={false}
                        className="w-full h-full object-cover charkle-media-zoom"
                      />
                    </button>
                  );
                })}
              </div>
            )}
          </div>
        ) : (
          /* Tab 1: Reorderable Single Asset Info Cards (9 macOS InspectorInfoSection cards) */
          asset && (
            <div className="flex flex-col gap-2.5 pb-2 charkle-pane-fade">
              {visibleSections.map((section) => renderSingleAssetCard(section, asset))}

              {isOrderCustomized && (
                <button
                  type="button"
                  onClick={() => {
                    resetInspectorCardOrder();
                    pushToast({ message: '已恢复信息栏默认排序', tone: 'info', durationMs: 2200 });
                  }}
                  className="charkle-pressable mx-auto mt-0.5 inline-flex items-center gap-1 px-2.5 py-[5px] rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)]/80 hover:bg-[var(--bg-subtle)] text-[10.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                >
                  <ArrowReset20Regular className="w-3 h-3" />
                  <span>恢复信息栏默认排序</span>
                </button>
              )}
            </div>
          )
        )}
      </div>

      {/* Add to Moodboard Popover (z-[170] so it renders cleanly above QuickLook z-[130]) */}
      <Popover
        open={boardMenuOpen && Boolean(asset)}
        onOpenChange={setBoardMenuOpen}
        anchorEl={boardBtnRef.current}
        placement="bottom-start"
        className="!z-[170] w-[206px] p-1"
      >
        {asset && (
          <div className="flex flex-col gap-0.5 text-[12px]">
            {boards.length === 0 ? (
              <div className="px-2.5 py-1.5 text-[11.5px] text-[var(--text-tertiary)]">
                暂无情绪板
              </div>
            ) : (
              boards.map((board) => (
                <button
                  key={board.id}
                  type="button"
                  onClick={() => {
                    setBoardMenuOpen(false);
                    void addAssetsToBoard(board.id, [asset.id]);
                  }}
                  className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] truncate cursor-pointer"
                >
                  {board.title}
                </button>
              ))
            )}
            <div className="my-1 h-px bg-[var(--border-hairline)]" />
            <button
              type="button"
              onClick={() => {
                setBoardMenuOpen(false);
                setSelection([asset.id], asset.id);
                if (isQuickLookHosted) {
                  onRequestCloseQuickLook?.();
                }
                openMoodboardGenerator('seedAssets');
              }}
              className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--accent)] font-medium hover:bg-[var(--accent-soft)] cursor-pointer"
            >
              以此图快速生成新情绪板…
            </button>
          </div>
        )}
      </Popover>

      {/* Single-Asset Hierarchical Folder Move Popover */}
      <Popover
        open={folderMenuOpen && Boolean(asset)}
        onOpenChange={setFolderMenuOpen}
        anchorEl={folderBtnRef.current}
        placement="bottom-end"
        className="!z-[170] p-1"
      >
        {asset && (
          <FolderMoveMenu
            folders={folders}
            currentFolderId={asset.folderID ?? null}
            highlightSelection
            parentSelfPrefix="放入"
            onSelectFolder={(folderId) => {
              setFolderMenuOpen(false);
              void updateAssets(
                {
                  assetIDs: [asset.id],
                  folderAssignment: folderId ? { folder: folderId } : 'inbox',
                },
                destination,
              );
            }}
          />
        )}
      </Popover>

      {/* Multi-Select Hierarchical Folder Move Popover */}
      <Popover
        open={batchFolderMenuOpen && selectedAssets.length > 1}
        onOpenChange={setBatchFolderMenuOpen}
        anchorEl={batchFolderBtnRef.current}
        placement="bottom-start"
        className="!z-[170] p-1"
      >
        <FolderMoveMenu
          folders={folders}
          highlightSelection={false}
          parentSelfPrefix="放入"
          onSelectFolder={(folderId) => {
            setBatchFolderMenuOpen(false);
            const ids = selectedAssets.map((a) => a.id);
            const targetName = folderId ? folderLabelFor(folderId) : '收件箱';
            void updateAssets(
              {
                assetIDs: ids,
                folderAssignment: folderId ? { folder: folderId } : 'inbox',
              },
              destination,
            ).then(() =>
              pushToast({
                message: `已将 ${ids.length} 项移至「${targetName}」`,
                tone: 'success',
              }),
            );
          }}
        />
      </Popover>

      {/* Swatch Right-Click Context Menu */}
      <Popover
        open={swatchMenu !== null}
        onOpenChange={(open) => {
          if (!open) setSwatchMenu(null);
        }}
        anchorPoint={swatchMenu?.point ?? null}
        className="!z-[170] w-[166px] p-1"
      >
        {swatchMenu && (
          <div className="flex flex-col gap-0.5 text-[12px]">
            <button
              type="button"
              onClick={() => {
                const hex = swatchMenu.hex;
                setSwatchMenu(null);
                void copyText(hex, `已复制色值 ${hex}`);
              }}
              className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              复制 {swatchMenu.hex}
            </button>
            <button
              type="button"
              onClick={() => {
                const hex = swatchMenu.hex;
                setSwatchMenu(null);
                handleFilterByColor(hex);
              }}
              className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              以此色筛选素材库
            </button>
          </div>
        )}
      </Popover>

      {/* AI Suggested Tag Right-Click Context Menu */}
      <Popover
        open={suggestedTagMenu !== null && Boolean(asset)}
        onOpenChange={(open) => {
          if (!open) setSuggestedTagMenu(null);
        }}
        anchorPoint={suggestedTagMenu?.point ?? null}
        className="!z-[170] w-[166px] p-1"
      >
        {suggestedTagMenu && asset && (
          <div className="flex flex-col gap-0.5 text-[12px]">
            <button
              type="button"
              onClick={() => {
                const tag = suggestedTagMenu.tag;
                setSuggestedTagMenu(null);
                void updateAssets(
                  {
                    assetIDs: [asset.id],
                    addTags: [tag],
                    dismissSuggestedTags: [tag],
                  },
                  destination,
                );
              }}
              className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] truncate cursor-pointer"
            >
              采纳「{suggestedTagMenu.tag}」
            </button>
            <button
              type="button"
              onClick={() => {
                const tag = suggestedTagMenu.tag;
                setSuggestedTagMenu(null);
                void updateAssets(
                  { assetIDs: [asset.id], dismissSuggestedTags: [tag] },
                  destination,
                );
              }}
              className="charkle-pressable w-full text-left px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
            >
              忽略此建议
            </button>
          </div>
        )}
      </Popover>

      {/* Card Header Reorder Context Menu (1:1 macOS InspectorView.swift lines 2409-2457) */}
      <Popover
        open={cardContextMenu !== null}
        onOpenChange={(open) => {
          if (!open) setCardContextMenu(null);
        }}
        anchorPoint={cardContextMenu?.point ?? null}
        className="!z-[170] w-[164px] p-1"
      >
        {cardContextMenu && (
          <div className="flex flex-col gap-0.5 text-[12px]">
            <button
              type="button"
              disabled={contextCardIsFirst}
              onClick={() => {
                moveInspectorCardToTop(cardContextMenu.cardId);
                setCardContextMenu(null);
              }}
              className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] disabled:opacity-40 disabled:pointer-events-none cursor-pointer"
            >
              <AlignTop16Regular className="w-3.5 h-3.5 text-[var(--text-secondary)]" />
              <span>移到最顶部</span>
            </button>
            <button
              type="button"
              disabled={contextCardIsFirst}
              onClick={() => {
                stepInspectorCard(cardContextMenu.cardId, -1, visibleSections);
                setCardContextMenu(null);
              }}
              className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] disabled:opacity-40 disabled:pointer-events-none cursor-pointer"
            >
              <ArrowUp16Regular className="w-3.5 h-3.5 text-[var(--text-secondary)]" />
              <span>上移一项</span>
            </button>
            <button
              type="button"
              disabled={contextCardIsLast}
              onClick={() => {
                stepInspectorCard(cardContextMenu.cardId, 1, visibleSections);
                setCardContextMenu(null);
              }}
              className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] disabled:opacity-40 disabled:pointer-events-none cursor-pointer"
            >
              <ArrowDown16Regular className="w-3.5 h-3.5 text-[var(--text-secondary)]" />
              <span>下移一项</span>
            </button>
            <button
              type="button"
              disabled={contextCardIsLast}
              onClick={() => {
                moveInspectorCardToBottom(cardContextMenu.cardId);
                setCardContextMenu(null);
              }}
              className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] disabled:opacity-40 disabled:pointer-events-none cursor-pointer"
            >
              <AlignBottom16Regular className="w-3.5 h-3.5 text-[var(--text-secondary)]" />
              <span>移到最底部</span>
            </button>

            {isOrderCustomized && (
              <>
                <div className="my-1 h-px bg-[var(--win-stroke-divider)]" />
                <button
                  type="button"
                  onClick={() => {
                    resetInspectorCardOrder();
                    setCardContextMenu(null);
                    pushToast({ message: '已恢复信息栏默认排序', tone: 'info' });
                  }}
                  className="charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                >
                  <ArrowReset20Regular className="w-3.5 h-3.5 text-[var(--text-secondary)]" />
                  <span>恢复默认排序</span>
                </button>
              </>
            )}
          </div>
        )}
      </Popover>

      {/* Permanent Delete Confirmation Modal (portal at z-[180] so it sits cleanly above Quick Look) */}
      {pendingDeleteIds.length > 0 &&
        typeof document !== 'undefined' &&
        createPortal(
          <div
            role="dialog"
            aria-modal="true"
            aria-label="彻底删除确认"
            data-inspector-delete-open="true"
            onMouseDown={(e) => e.stopPropagation()}
            onPointerDown={(e) => e.stopPropagation()}
            onClick={(e) => e.stopPropagation()}
            className="fixed inset-0 z-[180] flex items-center justify-center p-4"
          >
            <div
              className="win-smoke-scrim fixed inset-0"
              onClick={() => setPendingDeleteIds([])}
            />
            <div className="relative z-10 w-full max-w-[380px] rounded-[var(--win-radius-dialog)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-flyout)] shadow-[var(--shadow-modal)] p-5 flex flex-col gap-3">
              <div className="text-[15px] font-semibold text-[var(--text-primary)]">
                彻底删除 {pendingDeleteIds.length} 项素材？
              </div>
              <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed">
                彻底删除后将无法从回收站恢复。
              </p>
              <div className="flex items-center justify-end gap-2 pt-1">
                <Button variant="standard" size="sm" onClick={() => setPendingDeleteIds([])}>
                  取消
                </Button>
                <Button
                  variant="danger"
                  size="sm"
                  onClick={async () => {
                    const ids = [...pendingDeleteIds];
                    setPendingDeleteIds([]);
                    await permanentlyDeleteAssets(ids, destination);
                  }}
                >
                  彻底删除
                </Button>
              </div>
            </div>
          </div>,
          document.body,
        )}

      {/* Floating Pill Drag Ghost (Fluent acrylic card preview) */}
      {activeCardDrag &&
        typeof document !== 'undefined' &&
        createPortal(
          <div
            aria-hidden="true"
            style={{
              transform: `translate3d(${Math.round(activeCardDrag.x + 12)}px, ${Math.round(
                activeCardDrag.y + 12,
              )}px, 0)`,
            }}
            className="pointer-events-none fixed top-0 left-0 z-[260]"
          >
            <div className="win-acrylic inline-flex items-center gap-1.5 px-3 py-[7px] rounded-[var(--win-radius-card)] border border-[var(--accent)]/40 text-[12px] font-semibold text-[var(--text-primary)]">
              <span className="text-[var(--accent)] inline-flex items-center">
                {activeCardDrag.icon}
              </span>
              <span>{activeCardDrag.title}</span>
            </div>
          </div>,
          document.body,
        )}
    </aside>
  );
};
