import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowLeft,
  ChevronDown,
  CloudDownload,
  Download,
  LayoutGrid,
  Maximize2,
  PanelRight,
  Redo2,
  Sparkles,
  Star,
  Undo2,
} from 'lucide-react';
import {
  EDITORIAL_STYLES,
  cropCenterPoint,
  editorialStyleLocalizedLabel,
  freezeIntoFreeform,
  getBoardReferencedAssetIDs,
  isAutoEditorialMode,
  mapImagePointToVisibleCrop,
} from '@charkle/shared';
import type {
  BoardConnector,
  BoardNode,
  BoardPoint,
  EditorialStyle,
  MoodboardProposal,
  UUID,
} from '@charkle/shared';
import { apiClient, thumbnailURL } from '../../api/client';
import { BoardCanvasSkeleton, EmptyStateVignette } from '../../design-system';
import { Button } from '../../design-system/Button';
import { ModalShell } from '../../design-system/ModalShell';
import { Popover } from '../../design-system/Popover';
import { revealAssetInLibrary } from '../../lib/revealAssetInLibrary';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import { CandidatePoolPanel } from './CandidatePoolPanel';
import type { MoodboardDrawerTab } from './CandidatePoolPanel';
import { ExportBoardModal } from './ExportBoardModal';
import { MoodboardCanvasView } from './MoodboardCanvasView';
import { computeFitCamera, tidyNodesWithStyle } from './geometry';
import type { CameraState } from './geometry';

const BOARD_FIT_MARGIN = 64;
const BOARD_TOP_CLEARANCE = 76;
const BOARD_BOTTOM_CLEARANCE = 108;

function cameraClipsIntoCanvasHUD(
  nodes: readonly BoardNode[],
  cam: CameraState,
  viewportW: number,
  viewportH: number,
): boolean {
  if (nodes.length === 0 || viewportW < 200 || viewportH < 200) return false;
  let minX = Number.POSITIVE_INFINITY;
  let minY = Number.POSITIVE_INFINITY;
  let maxX = Number.NEGATIVE_INFINITY;
  let maxY = Number.NEGATIVE_INFINITY;
  for (const node of nodes) {
    minX = Math.min(minX, node.frame.x);
    minY = Math.min(minY, node.frame.y);
    maxX = Math.max(maxX, node.frame.x + node.frame.width);
    maxY = Math.max(maxY, node.frame.y + node.frame.height);
  }
  const screenMinY = (minY - cam.centerY) * cam.zoom + viewportH * 0.5;
  const screenMaxY = (maxY - cam.centerY) * cam.zoom + viewportH * 0.5;
  const screenMinX = (minX - cam.centerX) * cam.zoom + viewportW * 0.5;
  const screenMaxX = (maxX - cam.centerX) * cam.zoom + viewportW * 0.5;
  return (
    screenMinY < BOARD_TOP_CLEARANCE ||
    screenMaxY > viewportH - BOARD_BOTTOM_CLEARANCE ||
    screenMinX < 24 ||
    screenMaxX > viewportW - 24
  );
}

export interface MoodboardWorkspaceViewProps {
  boardID?: UUID;
}

export const MoodboardWorkspaceView: React.FC<MoodboardWorkspaceViewProps> = ({ boardID }) => {
  const destination = useCoordinatorStore((s) => s.destination);
  const navigate = useCoordinatorStore((s) => s.navigate);
  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
  const setActiveBoardID = useCoordinatorStore((s) => s.setActiveBoardID);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const assetsByID = useLibraryStore((s) => s.assetsByID);
  const libraryAssets = useLibraryStore((s) => s.assets);
  const cacheBustVersion = useLibraryStore((s) => s.cacheBustVersion);
  const upsertAssets = useLibraryStore((s) => s.upsertAssets);
  const uploadFiles = useLibraryStore((s) => s.uploadFiles);
  const setCriteria = useLibraryStore((s) => s.setCriteria);

  const activeDocument = useMoodboardStore((s) => s.activeDocument);
  const loadingBoard = useMoodboardStore((s) => s.loadingBoard);
  const savingBoard = useMoodboardStore((s) => s.savingBoard);
  const past = useMoodboardStore((s) => s.past);
  const future = useMoodboardStore((s) => s.future);
  const selectedNodeIDs = useMoodboardStore((s) => s.selectedNodeIDs);
  const swappingNodeID = useMoodboardStore((s) => s.swappingNodeID);
  const candidatePool = useMoodboardStore((s) => s.candidatePool);
  const loadingCandidates = useMoodboardStore((s) => s.loadingCandidates);

  const openBoard = useMoodboardStore((s) => s.openBoard);
  const mutateDocument = useMoodboardStore((s) => s.mutateDocument);
  const undo = useMoodboardStore((s) => s.undo);
  const redo = useMoodboardStore((s) => s.redo);
  const setSelectedNodeIDs = useMoodboardStore((s) => s.setSelectedNodeIDs);
  const toggleSelectNode = useMoodboardStore((s) => s.toggleSelectNode);
  const clearNodeSelection = useMoodboardStore((s) => s.clearNodeSelection);
  const setSwappingNodeID = useMoodboardStore((s) => s.setSwappingNodeID);
  const loadReplacementCandidates = useMoodboardStore((s) => s.loadReplacementCandidates);
  const swapNodeAsset = useMoodboardStore((s) => s.swapNodeAsset);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const resolvedBoardID =
    boardID ?? (destination.type === 'moodboard' ? destination.id : activeDocument?.id ?? null);

  const [candidateDrawerOpen, setCandidateDrawerOpen] = useState(false);
  const [drawerTab, setDrawerTab] = useState<MoodboardDrawerTab>('candidates');
  const [extractingPalette, setExtractingPalette] = useState(false);
  const [exportModalOpen, setExportModalOpen] = useState(false);
  const [viewportSize, setViewportSize] = useState({ width: 1120, height: 720 });
  const [viewportMeasured, setViewportMeasured] = useState(false);
  const [camera, setCamera] = useState<CameraState>({ centerX: 560, centerY: 380, zoom: 1.0 });
  const [tidyAnimating, setTidyAnimating] = useState(false);
  const [tidyMenuOpen, setTidyMenuOpen] = useState(false);
  const tidyTimerRef = useRef<number | null>(null);
  const tidyMenuAnchorRef = useRef<HTMLButtonElement | null>(null);
  const fittedBoardIDRef = useRef<UUID | null>(null);

  const handleViewportChange = useCallback((size: { width: number; height: number }) => {
    setViewportSize((prev) =>
      prev.width === size.width && prev.height === size.height ? prev : size,
    );
    setViewportMeasured(true);
  }, []);

  // Experimental Jev Box dialogs
  const [semanticCropTarget, setSemanticCropTarget] = useState<{ nodeID: UUID; assetID: UUID } | null>(null);
  const [semanticCropQuery, setSemanticCropQuery] = useState('');
  const [visualMatchTarget, setVisualMatchTarget] = useState<{ nodeID: UUID; assetID: UUID } | null>(null);
  const [pinpointTarget, setPinpointTarget] = useState<{ nodeID: UUID; assetID: UUID } | null>(null);
  const [pinpointQuery, setPinpointQuery] = useState('');
  const [pinpointNoteText, setPinpointNoteText] = useState('');
  const [jevBusy, setJevBusy] = useState(false);

  const loadedBoardRef = useRef<UUID | null>(null);

  // Load board when resolvedBoardID changes
  useEffect(() => {
    if (!resolvedBoardID) return;
    if (activeDocument?.id === resolvedBoardID) return;
    if (loadedBoardRef.current === resolvedBoardID && loadingBoard) return;
    loadedBoardRef.current = resolvedBoardID;
    void openBoard(resolvedBoardID);
  }, [resolvedBoardID, activeDocument?.id, loadingBoard, openBoard]);

  // Frame newly opened board cleanly between the top palette strip (76px) and bottom dock (108px)
  useEffect(() => {
    if (!activeDocument || !viewportMeasured) return;
    if (fittedBoardIDRef.current === activeDocument.id) return;
    fittedBoardIDRef.current = activeDocument.id;

    const savedCam: CameraState = {
      centerX: activeDocument.viewportCenter.x,
      centerY: activeDocument.viewportCenter.y,
      zoom: activeDocument.viewportZoom || 1.0,
    };
    const hasSavedCenter =
      Math.abs(savedCam.centerX) > 1 || Math.abs(savedCam.centerY) > 1;

    if (activeDocument.nodes.length === 0) {
      setCamera({
        centerX: viewportSize.width * 0.5,
        centerY: viewportSize.height * 0.5,
        zoom: savedCam.zoom,
      });
      return;
    }

    if (
      !hasSavedCenter ||
      cameraClipsIntoCanvasHUD(activeDocument.nodes, savedCam, viewportSize.width, viewportSize.height)
    ) {
      setCamera(
        computeFitCamera(
          activeDocument.nodes,
          viewportSize.width,
          viewportSize.height,
          BOARD_FIT_MARGIN,
          BOARD_TOP_CLEARANCE,
          BOARD_BOTTOM_CLEARANCE,
        ),
      );
    } else {
      setCamera(savedCam);
    }
  }, [activeDocument, viewportMeasured, viewportSize.width, viewportSize.height]);

  useEffect(() => {
    return () => {
      if (tidyTimerRef.current !== null) {
        window.clearTimeout(tidyTimerRef.current);
      }
    };
  }, []);

  const handleTidyBoard = useCallback(
    (style: EditorialStyle = 'balanced') => {
      if (!activeDocument || activeDocument.nodes.length === 0) return;
      setTidyMenuOpen(false);
      setTidyAnimating(true);
      if (tidyTimerRef.current !== null) {
        window.clearTimeout(tidyTimerRef.current);
      }
      tidyTimerRef.current = window.setTimeout(() => {
        tidyTimerRef.current = null;
        setTidyAnimating(false);
      }, 280);

      const isWholeBoardTidy = selectedNodeIDs.size < 2;
      const tidiedDoc = tidyNodesWithStyle(activeDocument, selectedNodeIDs, assetsByID, style);
      const fitCam = isWholeBoardTidy
        ? computeFitCamera(
            tidiedDoc.nodes,
            viewportSize.width,
            viewportSize.height,
            BOARD_FIT_MARGIN,
            BOARD_TOP_CLEARANCE,
            BOARD_BOTTOM_CLEARANCE,
          )
        : null;

      if (fitCam) {
        setCamera(fitCam);
      }

      mutateDocument(
        (doc) => {
          const next = tidyNodesWithStyle(doc, selectedNodeIDs, assetsByID, style);
          return fitCam
            ? {
                ...next,
                viewportCenter: { x: fitCam.centerX, y: fitCam.centerY },
                viewportZoom: fitCam.zoom,
              }
            : next;
        },
        { recordHistory: true, immediateSave: true },
      );
      pushToast({
        tone: 'success',
        message:
          selectedNodeIDs.size >= 2
            ? `已按「${editorialStyleLocalizedLabel(style)}」整齐排布选中的 ${selectedNodeIDs.size} 个元素`
            : `已按「${editorialStyleLocalizedLabel(style)}」重新整齐排版`,
      });
    },
    [
      activeDocument,
      selectedNodeIDs,
      assetsByID,
      viewportSize.width,
      viewportSize.height,
      mutateDocument,
      pushToast,
    ],
  );

  // Stable modal close handlers so ModalShell never drops Escape listeners on parent re-renders
  const handleCloseExportModal = useCallback(() => setExportModalOpen(false), []);
  const handleCloseSemanticCrop = useCallback(() => setSemanticCropTarget(null), []);
  const handleCloseVisualMatch = useCallback(() => setVisualMatchTarget(null), []);
  const handleClosePinpoint = useCallback(() => setPinpointTarget(null), []);

  // Ensure every referenced asset in the board is fetched into assetsByID
  useEffect(() => {
    if (!activeDocument) return;
    const missing = getBoardReferencedAssetIDs(activeDocument).filter((id) => !assetsByID[id]);
    if (missing.length === 0) return;
    let cancelled = false;
    void Promise.all(
      missing.slice(0, 40).map((id) => apiClient.getAsset(id).then((r) => r.asset).catch(() => null)),
    ).then((loaded) => {
      if (cancelled) return;
      const valid = loaded.filter((a): a is NonNullable<typeof a> => a !== null);
      if (valid.length > 0) upsertAssets(valid);
    });
    return () => {
      cancelled = true;
    };
  }, [activeDocument, assetsByID, upsertAssets]);

  // Auto-open Candidate Pool drawer on the Candidates tab when user clicks "换一张" on a card
  useEffect(() => {
    if (swappingNodeID) {
      setDrawerTab('candidates');
      setCandidateDrawerOpen(true);
    }
  }, [swappingNodeID]);

  const handleToggleDrawerTab = useCallback(
    (tab: MoodboardDrawerTab) => {
      if (candidateDrawerOpen && drawerTab === tab) {
        setCandidateDrawerOpen(false);
      } else {
        setDrawerTab(tab);
        setCandidateDrawerOpen(true);
      }
    },
    [candidateDrawerOpen, drawerTab],
  );

  const handleReextractPalette = useCallback(async () => {
    if (!activeDocument) return;
    const assetIDs = getBoardReferencedAssetIDs(activeDocument);
    if (assetIDs.length === 0) {
      pushToast({ tone: 'info', message: '画布中暂无图片素材' });
      return;
    }
    setExtractingPalette(true);
    try {
      const res = await apiClient.extractBoardPalette({ assetIDs, count: 7 });
      mutateDocument(
        (current) => ({
          ...current,
          extractedPalette: res.colors,
          nodes: current.nodes.map((node) =>
            node.kind.type === 'paletteStrip' &&
            (node.kind.autoSyncWithBoard || node.kind.colors.length === 0)
              ? { ...node, kind: { ...node.kind, colors: res.colors } }
              : node,
          ),
        }),
        { recordHistory: false, immediateSave: true },
      );
      pushToast({ tone: 'success', message: '已重新提取板内配色' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '重新提取配色失败',
      });
    } finally {
      setExtractingPalette(false);
    }
  }, [activeDocument, mutateDocument, pushToast]);

  const handleApplyCuratedProposal = useCallback(
    (proposal: MoodboardProposal) => {
      if (!activeDocument) return;
      const draft = proposal.draftDocument;
      const normalized = isAutoEditorialMode(draft.mode)
        ? freezeIntoFreeform(draft, Math.max(720, viewportSize.width), assetsByID)
        : draft;

      const fitCam = computeFitCamera(
        normalized.nodes,
        viewportSize.width,
        viewportSize.height,
        BOARD_FIT_MARGIN,
        BOARD_TOP_CLEARANCE,
        BOARD_BOTTOM_CLEARANCE,
      );
      setCamera(fitCam);

      mutateDocument(
        (current) => ({
          ...current,
          title: current.title || normalized.title,
          subtitle: current.subtitle || normalized.subtitle,
          mode: { type: 'freeform' },
          nodes: normalized.nodes,
          connectors: normalized.connectors,
          extractedPalette:
            proposal.extractedPalette.length > 0
              ? proposal.extractedPalette
              : normalized.extractedPalette.length > 0
                ? normalized.extractedPalette
                : current.extractedPalette,
          candidateAssetIDs:
            proposal.candidatePool.length > 0
              ? proposal.candidatePool.map((item) => item.asset.id)
              : normalized.candidateAssetIDs,
          viewportCenter: { x: fitCam.centerX, y: fitCam.centerY },
          viewportZoom: fitCam.zoom,
        }),
        { recordHistory: true, immediateSave: true },
      );

      if (proposal.candidatePool.length > 0) {
        useMoodboardStore.setState({ candidatePool: proposal.candidatePool });
      }

      pushToast({
        tone: 'success',
        message: '已应用 AI 策展微调',
        actionLabel: '撤销',
        durationMs: 5200,
        onAction: () => undo(),
      });
    },
    [
      activeDocument,
      assetsByID,
      viewportSize.width,
      viewportSize.height,
      mutateDocument,
      pushToast,
      undo,
    ],
  );

  const handleCameraChange = useCallback(
    (next: CameraState, persist = false) => {
      setCamera(next);
      if (persist && activeDocument) {
        mutateDocument(
          (doc) => ({
            ...doc,
            viewportCenter: { x: next.centerX, y: next.centerY },
            viewportZoom: next.zoom,
          }),
          { recordHistory: false, immediateSave: false },
        );
      }
    },
    [activeDocument, mutateDocument],
  );

  const handleCopyHex = useCallback(
    (hex: string) => {
      void navigator.clipboard?.writeText(hex);
      pushToast({ tone: 'success', message: `已复制色值 ${hex}` });
    },
    [pushToast],
  );

  const handleSearchColor = useCallback(
    (hex: string) => {
      setCriteria({ selectedColorHex: hex });
      navigate({ type: 'allItems' });
      pushToast({ tone: 'info', message: `正在按色值 ${hex} 筛选素材库` });
    },
    [setCriteria, navigate, pushToast],
  );

  const handleDropExternalFiles = useCallback(
    async (files: File[], worldPoint: BoardPoint | null) => {
      if (!activeDocument || files.length === 0) return;
      try {
        const uploaded = await uploadFiles(files, { targetFolderID: null, targetBoardID: null });
        if (uploaded.length > 0) {
          await addAssetsToBoard(
            activeDocument.id,
            uploaded.map((a) => a.id),
            worldPoint,
          );
          pushToast({
            tone: 'success',
            message: `已导入 ${uploaded.length} 项素材至收件箱并插入画布`,
          });
        }
      } catch (err) {
        pushToast({
          tone: 'error',
          message: err instanceof Error ? err.message : '导入文件至情绪板失败',
        });
      }
    },
    [activeDocument, uploadFiles, addAssetsToBoard, pushToast],
  );

  const handleDropLibraryAssetIDs = useCallback(
    async (assetIDs: UUID[], worldPoint: BoardPoint | null) => {
      if (!activeDocument || assetIDs.length === 0) return;
      await addAssetsToBoard(activeDocument.id, assetIDs, worldPoint);
      pushToast({ tone: 'success', message: `已将 ${assetIDs.length} 项素材插入情绪板` });
    },
    [activeDocument, addAssetsToBoard, pushToast],
  );

  // Jev Box Actions
  const handleSmartFocusSubject = useCallback(
    async (nodeID: UUID, assetID: UUID, query: string | null = null) => {
      setJevBusy(true);
      try {
        const { result } = await apiClient.locateVisualRegion({ assetID, query });
        if (!result.found) {
          pushToast({ tone: 'info', message: result.summary || '未在画面中定位到明确目标区域' });
          return;
        }
        mutateDocument((doc) => ({
          ...doc,
          nodes: doc.nodes.map((n) =>
            n.id === nodeID && n.kind.type === 'assetRef'
              ? { ...n, kind: { ...n.kind, crop: result.crop } }
              : n,
          ),
        }));
        pushToast({ tone: 'success', message: result.summary || '已应用智能裁切' });
      } catch (err) {
        pushToast({
          tone: 'error',
          message: err instanceof Error ? err.message : '智能聚焦裁切失败',
        });
      } finally {
        setJevBusy(false);
      }
    },
    [mutateDocument, pushToast],
  );

  const handleCleanContentCrop = useCallback(
    async (nodeID: UUID, assetID: UUID) => {
      setJevBusy(true);
      try {
        const { result } = await apiClient.detectCleanBounds(assetID);
        if (!result.recommendedCrop) {
          pushToast({ tone: 'info', message: result.summary || '画面主体已足够干净，无需裁边' });
          return;
        }
        mutateDocument((doc) => ({
          ...doc,
          nodes: doc.nodes.map((n) =>
            n.id === nodeID && n.kind.type === 'assetRef'
              ? { ...n, kind: { ...n.kind, crop: result.recommendedCrop } }
              : n,
          ),
        }));
        pushToast({ tone: 'success', message: result.summary || '已完成自动去杂边裁净' });
      } catch (err) {
        pushToast({
          tone: 'error',
          message: err instanceof Error ? err.message : '自动去杂边失败',
        });
      } finally {
        setJevBusy(false);
      }
    },
    [mutateDocument, pushToast],
  );

  const handleVisualMatchCrop = async (referenceAssetID: UUID) => {
    if (!visualMatchTarget) return;
    const { nodeID, assetID } = visualMatchTarget;
    setVisualMatchTarget(null);
    setJevBusy(true);
    try {
      const { result } = await apiClient.locateVisualMatch({
        referenceAssetID,
        targetAssetID: assetID,
      });
      if (!result.found) {
        pushToast({ tone: 'info', message: result.summary || '未找到与参考图匹配的局部区域' });
        return;
      }
      mutateDocument((doc) => ({
        ...doc,
        nodes: doc.nodes.map((n) =>
          n.id === nodeID && n.kind.type === 'assetRef'
            ? { ...n, kind: { ...n.kind, crop: result.crop } }
            : n,
        ),
      }));
      pushToast({ tone: 'success', message: '已按参考图局部匹配裁切' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '按参考图匹配区域失败',
      });
    } finally {
      setJevBusy(false);
    }
  };

  const handleSubmitPinpoint = async () => {
    if (!pinpointTarget || !activeDocument || !pinpointQuery.trim()) return;
    const { nodeID, assetID } = pinpointTarget;
    const query = pinpointQuery.trim();
    const noteBody = pinpointNoteText.trim() || `细节批注：${query}`;
    setPinpointTarget(null);
    setJevBusy(true);
    try {
      const { result } = await apiClient.locateVisualRegion({ assetID, query });
      const targetNode = activeDocument.nodes.find((n) => n.id === nodeID);
      if (!targetNode) return;

      const rawCenter = cropCenterPoint(result.crop);
      const visiblePoint =
        targetNode.kind.type === 'assetRef' && targetNode.kind.crop
          ? mapImagePointToVisibleCrop(targetNode.kind.crop, rawCenter)
          : rawCenter;

      const now = new Date().toISOString();
      const maxZ = activeDocument.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
      const maxOrder = activeDocument.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);

      const noteNode: BoardNode = {
        id: crypto.randomUUID().toUpperCase(),
        kind: {
          type: 'note',
          title: query,
          text: noteBody,
          style: 'warm',
          fontSize: 13,
        },
        frame: {
          x: targetNode.frame.x + targetNode.frame.width + 44,
          y: targetNode.frame.y,
          width: 220,
          height: 128,
        },
        zIndex: maxZ + 1,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: maxOrder + 1,
        updatedAt: now,
      };

      const connector: BoardConnector = {
        id: crypto.randomUUID().toUpperCase(),
        fromNodeID: noteNode.id,
        fromAnchor: 'leading',
        fromNormalizedPoint: null,
        toNodeID: targetNode.id,
        toAnchor: 'auto',
        toNormalizedPoint: visiblePoint,
        label: null,
        colorHex: '#D95D48',
        style: 'curved',
        dashed: false,
        updatedAt: now,
      };

      mutateDocument(
        (doc) => ({
          ...doc,
          mode: { type: 'freeform' },
          nodes: [...doc.nodes, noteNode],
          connectors: [...doc.connectors, connector],
        }),
        { recordHistory: true, immediateSave: true },
      );
      pushToast({ tone: 'success', message: `已创建指向「${query}」的精准批注` });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '精准定位批注失败',
      });
    } finally {
      setJevBusy(false);
    }
  };

  const allLibraryAssets = useMemo(
    () => (libraryAssets.length > 0 ? libraryAssets : Object.values(assetsByID)),
    [libraryAssets, assetsByID],
  );

  if (loadingBoard && !activeDocument) {
    return (
      <div className="h-full w-full flex flex-col bg-[var(--bg-gallery)] overflow-hidden">
        <BoardCanvasSkeleton active delayMs={300} minVisibleMs={500} />
      </div>
    );
  }

  if (!activeDocument) {
    return (
      <div className="h-full w-full flex flex-col items-center justify-center bg-[var(--bg-gallery)] gap-3 text-[var(--text-secondary)]">
        <EmptyStateVignette kind="emptyMoodboard" />
        <p className="text-[13.5px] font-medium text-[var(--text-primary)]">未选择情绪板</p>
        <Button variant="secondary" size="sm" onClick={() => navigate({ type: 'moodboardsHome' })}>
          返回情绪板列表
        </Button>
      </div>
    );
  }

  const isActiveTarget = activeBoardID === activeDocument.id;

  return (
    <div className="h-full w-full flex flex-col bg-[var(--bg-gallery)] overflow-hidden">
      {/* Top Clean Workspace Header (solid elevated surface — zero glass blur on permanent chrome) */}
      <header className="h-13 px-4 border-b border-[var(--border-hairline)] bg-[var(--bg-elevated)] flex items-center justify-between gap-3 shrink-0 z-20">
        {/* Left: Back + Editable Title & Subtitle */}
        <div className="flex items-center gap-2.5 min-w-0 flex-1">
          <button
            type="button"
            onClick={() => navigate({ type: 'moodboardsHome' })}
            aria-label="返回全部情绪板"
            title="返回全部情绪板"
            className="charkle-pressable w-8 h-8 rounded-[var(--radius-chip)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] shrink-0 cursor-pointer"
          >
            <ArrowLeft size={16} />
          </button>

          <div className="min-w-0 flex flex-col">
            <div className="flex items-center gap-2">
              <input
                type="text"
                aria-label="情绪板标题"
                value={activeDocument.title}
                onChange={(e) =>
                  mutateDocument((doc) => ({ ...doc, title: e.target.value }), {
                    recordHistory: false,
                  })
                }
                className="min-w-[80px] max-w-[260px] bg-transparent border-0 outline-none text-[14px] font-semibold text-[var(--text-primary)] focus:bg-[var(--bg-subtle)] rounded px-1 -ml-1 truncate"
              />
              {savingBoard && (
                <span className="text-[10.5px] text-[var(--text-tertiary)] shrink-0">保存中…</span>
              )}
              {jevBusy && (
                <span className="text-[10.5px] text-[var(--accent)] font-medium shrink-0">
                  分析中…
                </span>
              )}
            </div>
            <input
              type="text"
              aria-label="情绪板副标题"
              value={activeDocument.subtitle}
              placeholder="添加副标题…"
              onChange={(e) =>
                mutateDocument((doc) => ({ ...doc, subtitle: e.target.value }), {
                  recordHistory: false,
                })
              }
              className="min-w-[120px] max-w-[300px] bg-transparent border-0 outline-none text-[11px] text-[var(--text-secondary)] placeholder:text-[var(--text-tertiary)] focus:bg-[var(--bg-subtle)] rounded px-1 -ml-1 truncate"
            />
          </div>
        </div>

        {/* Center: Unified Freeform Controls */}
        <div className="hidden lg:flex items-center gap-2 shrink-0">
          <span className="text-[11.5px] font-mono text-[var(--text-secondary)] px-2 tabular-nums">
            {Math.round(camera.zoom * 100)}%
          </span>
          <Button
            variant="ghost"
            size="xs"
            onClick={() =>
              handleCameraChange(
                computeFitCamera(
                  activeDocument.nodes,
                  viewportSize.width,
                  viewportSize.height,
                  BOARD_FIT_MARGIN,
                  BOARD_TOP_CLEARANCE,
                  BOARD_BOTTOM_CLEARANCE,
                ),
                true,
              )
            }
            title="适配全部画布内容"
          >
            <Maximize2 size={13} />
            适配
          </Button>

          {/* One-Click Tidy + Editorial Rhythm Presets */}
          <div className="inline-flex items-center rounded-[var(--radius-chip)] border border-[var(--border-hairline)] bg-[var(--bg-subtle)]/75 overflow-hidden">
            <button
              type="button"
              disabled={activeDocument.nodes.length === 0}
              onClick={() => handleTidyBoard('balanced')}
              title="重新整齐排版（整理选中项或整板）"
              className="charkle-pressable inline-flex items-center gap-1.5 h-7 px-2.5 text-[11.5px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-elevated)] disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]"
            >
              <LayoutGrid size={13} />
              重新排版
            </button>
            <span className="w-px h-4 bg-[var(--border-hairline)]" />
            <button
              ref={tidyMenuAnchorRef}
              type="button"
              disabled={activeDocument.nodes.length === 0}
              onClick={() => setTidyMenuOpen((v) => !v)}
              aria-label="选择重新排版节奏预设"
              aria-expanded={tidyMenuOpen}
              title="选择排版节奏预设（呼吸均衡 / 杂志主次 / 紧凑拼贴）"
              className="charkle-pressable inline-flex items-center justify-center h-7 w-6 text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-elevated)] disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]"
            >
              <ChevronDown size={12} />
            </button>
          </div>

          <Popover
            open={tidyMenuOpen}
            onOpenChange={setTidyMenuOpen}
            anchorEl={tidyMenuAnchorRef.current}
            placement="bottom-end"
            className="w-56 p-1.5"
          >
            <div className="px-2 py-1 text-[10.5px] font-semibold text-[var(--text-tertiary)]">
              排版预设
            </div>
            <div className="flex flex-col gap-0.5">
              {EDITORIAL_STYLES.map((style: EditorialStyle) => (
                <button
                  key={style}
                  type="button"
                  onClick={() => handleTidyBoard(style)}
                  className="charkle-pressable w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-left hover:bg-[var(--bg-subtle)] cursor-pointer transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]"
                >
                  <div className="text-[12px] font-medium text-[var(--text-primary)]">
                    {editorialStyleLocalizedLabel(style)}
                  </div>
                </button>
              ))}
            </div>
          </Popover>

          <Button
            variant="ghost"
            size="icon"
            disabled={past.length === 0}
            onClick={undo}
            title="撤销 (⌘Z)"
          >
            <Undo2 size={14} />
          </Button>
          <Button
            variant="ghost"
            size="icon"
            disabled={future.length === 0}
            onClick={redo}
            title="重做 (⇧⌘Z)"
          >
            <Redo2 size={14} />
          </Button>
        </div>

        {/* Right: Active Board + Offline Pin + Candidate Pool + Export */}
        <div className="flex items-center gap-1.5 shrink-0">
          <Button
            variant="ghost"
            size="xs"
            active={isActiveTarget}
            onClick={() => {
              setActiveBoardID(isActiveTarget ? null : activeDocument.id);
              pushToast({
                tone: 'success',
                message: isActiveTarget
                  ? '已取消活跃采集目标'
                  : `已将「${activeDocument.title}」设为快速采集目标情绪板`,
              });
            }}
            title="设为默认采集目标"
          >
            <Star size={13} fill={isActiveTarget ? 'currentColor' : 'none'} />
            <span className="hidden sm:inline">{isActiveTarget ? '活跃情绪板' : '设为活跃'}</span>
          </Button>

          <Button
            variant="ghost"
            size="xs"
            active={activeDocument.pinnedOffline}
            onClick={() => {
              const nextPinned = !activeDocument.pinnedOffline;
              mutateDocument((doc) => ({ ...doc, pinnedOffline: nextPinned }), {
                recordHistory: false,
                immediateSave: true,
              });
              pushToast({
                tone: 'success',
                message: nextPinned ? '已为当前情绪板开启离线保留' : '已取消离线保留',
              });
            }}
            title="离线保留"
          >
            <CloudDownload size={13} />
            <span className="hidden md:inline">离线</span>
          </Button>

          <Button
            variant="secondary"
            size="xs"
            active={candidateDrawerOpen && drawerTab === 'curator'}
            onClick={() => handleToggleDrawerTab('curator')}
          >
            <Sparkles size={13} />
            AI 策展
          </Button>

          <Button
            variant="secondary"
            size="xs"
            active={candidateDrawerOpen && drawerTab === 'candidates'}
            onClick={() => handleToggleDrawerTab('candidates')}
          >
            <PanelRight size={13} />
            候选池
          </Button>

          <Button variant="primary" size="xs" onClick={() => setExportModalOpen(true)}>
            <Download size={13} />
            导出
          </Button>
        </div>
      </header>

      {/* Main Split: Unified Freeform Canvas + Slide-Out Candidate Pool Drawer */}
      <div className="flex-1 min-h-0 flex overflow-hidden relative">
        <MoodboardCanvasView
          document={activeDocument}
          assetsByID={assetsByID}
          cacheBustVersion={cacheBustVersion}
          selectedNodeIDs={selectedNodeIDs}
          swappingNodeID={swappingNodeID}
          canUndo={past.length > 0}
          canRedo={future.length > 0}
          camera={camera}
          tidyAnimating={tidyAnimating}
          drawerOpen={candidateDrawerOpen}
          onCameraChange={handleCameraChange}
          onViewportChange={handleViewportChange}
          onSelectNodes={setSelectedNodeIDs}
          onToggleSelectNode={toggleSelectNode}
          onClearSelection={clearNodeSelection}
          onCommitDocument={mutateDocument}
          onTidyBoard={() => handleTidyBoard('balanced')}
          onUndo={undo}
          onRedo={redo}
          onTriggerSwap={(nodeID) => {
            setSwappingNodeID(nodeID);
            setCandidateDrawerOpen(true);
          }}
          onOpenQuickLook={(asset) => openQuickLook(asset.id)}
          onRevealInLibrary={(assetID) =>
            void revealAssetInLibrary(assetID, {
              returnBoardId: activeDocument.id,
              returnBoardTitle: activeDocument.title,
            })
          }
          onCopyHex={handleCopyHex}
          onSearchColor={handleSearchColor}
          onOpenExport={() => setExportModalOpen(true)}
          onDropExternalFiles={(files, pt) => void handleDropExternalFiles(files, pt)}
          onDropLibraryAssetIDs={(ids, pt) => void handleDropLibraryAssetIDs(ids, pt)}
          onSmartFocusSubject={(nodeID, assetID) => void handleSmartFocusSubject(nodeID, assetID, null)}
          onSemanticCropPrompt={(nodeID, assetID) => {
            setSemanticCropTarget({ nodeID, assetID });
            setSemanticCropQuery('');
          }}
          onVisualMatchCrop={(nodeID, assetID) => setVisualMatchTarget({ nodeID, assetID })}
          onCleanContentCrop={(nodeID, assetID) => void handleCleanContentCrop(nodeID, assetID)}
          onPinpointAnnotate={(nodeID, assetID) => {
            setPinpointTarget({ nodeID, assetID });
            setPinpointQuery('');
            setPinpointNoteText('');
          }}
        />

        <CandidatePoolPanel
          open={candidateDrawerOpen}
          activeTab={drawerTab}
          onChangeTab={setDrawerTab}
          document={activeDocument}
          assetsByID={assetsByID}
          allLibraryAssets={allLibraryAssets}
          cacheBustVersion={cacheBustVersion}
          swappingNodeID={swappingNodeID}
          candidatePool={candidatePool}
          loadingCandidates={loadingCandidates}
          canUndo={past.length > 0}
          extractingPalette={extractingPalette}
          onClose={() => setCandidateDrawerOpen(false)}
          onCancelSwap={() => setSwappingNodeID(null)}
          onRefreshCandidates={(seedID) => void loadReplacementCandidates(seedID, 32)}
          onSwapWithAsset={(nodeID, newAssetID) => void swapNodeAsset(nodeID, newAssetID)}
          onAppendAsset={(assetID) => void addAssetsToBoard(activeDocument.id, [assetID], null)}
          onReextractPalette={() => void handleReextractPalette()}
          onCopyHex={handleCopyHex}
          onSearchColor={handleSearchColor}
          onApplyCuratedProposal={handleApplyCuratedProposal}
          onUndo={undo}
        />
      </div>

      {/* Export Modal (High-DPI PNG/JPG + Offline .charkleboard Figma Bridge) */}
      <ExportBoardModal
        open={exportModalOpen}
        onClose={handleCloseExportModal}
        document={activeDocument}
        containerWidth={viewportSize.width}
      />

      {/* Jev Box Dialog 1: Semantic Crop Prompt */}
      <ModalShell
        open={Boolean(semanticCropTarget)}
        onClose={handleCloseSemanticCrop}
        width="sm"
        title="语义裁切"
        footer={
          <>
            <Button variant="secondary" size="sm" onClick={handleCloseSemanticCrop}>
              取消
            </Button>
            <Button
              variant="primary"
              size="sm"
              disabled={!semanticCropQuery.trim()}
              onClick={() => {
                if (!semanticCropTarget) return;
                const { nodeID, assetID } = semanticCropTarget;
                const q = semanticCropQuery.trim();
                setSemanticCropTarget(null);
                void handleSmartFocusSubject(nodeID, assetID, q);
              }}
            >
              定位并聚焦
            </Button>
          </>
        }
      >
        <input
          type="text"
          autoFocus
          value={semanticCropQuery}
          onChange={(e) => setSemanticCropQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && semanticCropQuery.trim() && semanticCropTarget) {
              const { nodeID, assetID } = semanticCropTarget;
              const q = semanticCropQuery.trim();
              setSemanticCropTarget(null);
              void handleSmartFocusSubject(nodeID, assetID, q);
            }
          }}
          placeholder="例如：陶瓷花瓶手柄、左侧建筑立面、主角面部特写…"
          className="w-full h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[13px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
        />
      </ModalShell>

      {/* Jev Box Dialog 2: Visual Match Crop Reference Picker */}
      <ModalShell
        open={Boolean(visualMatchTarget)}
        onClose={handleCloseVisualMatch}
        width="md"
        title="按参考图匹配区域"
      >
        <div className="grid grid-cols-4 gap-2 max-h-[340px] overflow-y-auto charkle-scroll">
          {allLibraryAssets
            .filter((a) => !a.isTrashed && a.id !== visualMatchTarget?.assetID)
            .slice(0, 24)
            .map((asset) => (
              <button
                key={asset.id}
                type="button"
                onClick={() => void handleVisualMatchCrop(asset.id)}
                className="charkle-pressable group relative aspect-square rounded-[var(--radius-settings-inner)] overflow-hidden bg-[var(--bg-subtle)] border border-[var(--border-hairline)] hover:border-[var(--accent)] cursor-pointer"
              >
                <img
                  src={thumbnailURL(asset.id, 'grid520', cacheBustVersion)}
                  alt={asset.title}
                  className="w-full h-full object-cover"
                />
                <span className="absolute inset-x-0 bottom-0 px-1.5 py-1 bg-black/55 text-white text-[10px] truncate">
                  {asset.title}
                </span>
              </button>
            ))}
        </div>
      </ModalShell>

      {/* Jev Box Dialog 3: Pinpoint Callout Annotation */}
      <ModalShell
        open={Boolean(pinpointTarget)}
        onClose={handleClosePinpoint}
        width="sm"
        title="指物批注"
        footer={
          <>
            <Button variant="secondary" size="sm" onClick={handleClosePinpoint}>
              取消
            </Button>
            <Button
              variant="primary"
              size="sm"
              disabled={!pinpointQuery.trim()}
              onClick={() => void handleSubmitPinpoint()}
            >
              定位并生成批注
            </Button>
          </>
        }
      >
        <div className="flex flex-col gap-3">
          <div>
            <label className="block text-[12px] font-medium text-[var(--text-primary)] mb-1">
              要定位的画面元素
            </label>
            <input
              type="text"
              autoFocus
              value={pinpointQuery}
              onChange={(e) => setPinpointQuery(e.target.value)}
              placeholder="例如：金属按钮质感、顶部导航栏留白…"
              className="w-full h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[13px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
            />
          </div>
          <div>
            <label className="block text-[12px] font-medium text-[var(--text-primary)] mb-1">
              批注便签内容
            </label>
            <textarea
              rows={3}
              value={pinpointNoteText}
              onChange={(e) => setPinpointNoteText(e.target.value)}
              placeholder="记录设计参考点或改动建议…"
              className="w-full p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)] resize-none"
            />
          </div>
        </div>
      </ModalShell>
    </div>
  );
};
