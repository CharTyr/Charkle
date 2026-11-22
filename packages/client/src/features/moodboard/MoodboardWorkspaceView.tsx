import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowLeft,
  CloudDownload,
  Download,
  LayoutGrid,
  Maximize2,
  Palette,
  PanelRight,
  Redo2,
  Star,
  Undo2,
} from 'lucide-react';
import {
  EDITORIAL_STYLES,
  createDefaultAutoLayoutConfig,
  cropCenterPoint,
  editorialStyleLocalizedLabel,
  getBoardReferencedAssetIDs,
  isAutoEditorialMode,
  mapImagePointToVisibleCrop,
  tidyNodesInFreeform,
} from '@charkle/shared';
import type {
  BoardConnector,
  BoardNode,
  BoardPoint,
  EditorialStyle,
  UUID,
} from '@charkle/shared';
import { apiClient, thumbnailURL } from '../../api/client';
import { Button } from '../../design-system/Button';
import { CharkleIcon } from '../../design-system/CharkleIcon';
import { ModalShell } from '../../design-system/ModalShell';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import { CandidatePoolPanel } from './CandidatePoolPanel';
import { ExportBoardModal } from './ExportBoardModal';
import { MoodboardCanvasView } from './MoodboardCanvasView';
import { computeFitCamera } from './geometry';
import type { CameraState } from './geometry';

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
  const [exportModalOpen, setExportModalOpen] = useState(false);
  const [viewportWidth, setViewportWidth] = useState(1120);
  const [camera, setCamera] = useState<CameraState>({ centerX: 560, centerY: 380, zoom: 1.0 });

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

  // Sync camera from newly opened board document (leaving ~56px top clearance below palette strip)
  useEffect(() => {
    if (!activeDocument) return;
    const hasSavedCenter =
      Math.abs(activeDocument.viewportCenter.x) > 1 || Math.abs(activeDocument.viewportCenter.y) > 1;
    if (hasSavedCenter) {
      setCamera({
        centerX: activeDocument.viewportCenter.x,
        centerY: activeDocument.viewportCenter.y,
        zoom: activeDocument.viewportZoom || 1.0,
      });
    } else if (!isAutoEditorialMode(activeDocument.mode) && activeDocument.nodes.length > 0) {
      setCamera(computeFitCamera(activeDocument.nodes, viewportWidth, 720, 72, 64, 96));
    } else {
      setCamera({ centerX: 560, centerY: 324, zoom: activeDocument.viewportZoom || 1.0 });
    }
  }, [activeDocument?.id]);

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

  // Auto-open Candidate Pool drawer when user clicks "换一张" on a card
  useEffect(() => {
    if (swappingNodeID) {
      setCandidateDrawerOpen(true);
    }
  }, [swappingNodeID]);

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
        pushToast({ tone: 'success', message: result.summary || '已应用非破坏性智能聚焦裁切' });
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
      <div className="h-full w-full flex items-center justify-center bg-[var(--bg-gallery)] text-[var(--text-secondary)] text-[13px]">
        正在加载情绪板画布…
      </div>
    );
  }

  if (!activeDocument) {
    return (
      <div className="h-full w-full flex flex-col items-center justify-center bg-[var(--bg-gallery)] gap-3 text-[var(--text-secondary)]">
        <CharkleIcon name="moodboard" style="layered" size={48} />
        <p className="text-[13.5px]">未选择情绪板</p>
        <Button variant="secondary" size="sm" onClick={() => navigate({ type: 'moodboardsHome' })}>
          返回情绪板列表
        </Button>
      </div>
    );
  }

  const isAuto = isAutoEditorialMode(activeDocument.mode);
  const autoConfig =
    activeDocument.mode.type === 'autoEditorial'
      ? activeDocument.mode.config
      : createDefaultAutoLayoutConfig();
  const isActiveTarget = activeBoardID === activeDocument.id;

  const updateAutoConfig = (patch: Partial<typeof autoConfig>) => {
    mutateDocument((doc) => ({
      ...doc,
      mode: {
        type: 'autoEditorial',
        config: {
          ...(doc.mode.type === 'autoEditorial' ? doc.mode.config : createDefaultAutoLayoutConfig()),
          ...patch,
        },
      },
    }));
  };

  return (
    <div className="h-full w-full flex flex-col bg-[var(--bg-gallery)] overflow-hidden">
      {/* Top Clean Workspace Header */}
      <header className="h-13 px-4 border-b border-[var(--border-hairline)] bg-[var(--bg-elevated)]/92 backdrop-blur-md flex items-center justify-between gap-3 shrink-0 z-20">
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
                  Jev Box 分析中…
                </span>
              )}
            </div>
            <input
              type="text"
              aria-label="情绪板副标题"
              value={activeDocument.subtitle}
              placeholder="添加副标题或项目方向…"
              onChange={(e) =>
                mutateDocument((doc) => ({ ...doc, subtitle: e.target.value }), {
                  recordHistory: false,
                })
              }
              className="min-w-[120px] max-w-[300px] bg-transparent border-0 outline-none text-[11px] text-[var(--text-secondary)] placeholder:text-[var(--text-tertiary)] focus:bg-[var(--bg-subtle)] rounded px-1 -ml-1 truncate"
            />
          </div>
        </div>

        {/* Center: Mode-specific controls */}
        <div className="hidden lg:flex items-center gap-2 shrink-0">
          {isAuto ? (
            <>
              <div className="inline-flex p-0.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)]">
                {EDITORIAL_STYLES.map((style: EditorialStyle) => (
                  <button
                    key={style}
                    type="button"
                    onClick={() => updateAutoConfig({ style })}
                    className={[
                      'px-2.5 py-1 rounded-[6px] text-[11.5px] font-medium cursor-pointer',
                      autoConfig.style === style
                        ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-xs'
                        : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                    ].join(' ')}
                  >
                    {editorialStyleLocalizedLabel(style)}
                  </button>
                ))}
              </div>

              <label className="inline-flex items-center gap-1.5 text-[11.5px] text-[var(--text-secondary)] px-2">
                <span>间距</span>
                <input
                  type="range"
                  min={6}
                  max={32}
                  step={2}
                  value={autoConfig.spacing}
                  onChange={(e) => updateAutoConfig({ spacing: Number(e.target.value) })}
                  className="w-16 accent-[var(--accent)] cursor-pointer"
                />
              </label>

              <Button
                variant="ghost"
                size="xs"
                active={autoConfig.showPaletteStrip}
                onClick={() => updateAutoConfig({ showPaletteStrip: !autoConfig.showPaletteStrip })}
                title="显示 / 隐藏顶部板内色卡条"
              >
                <Palette size={13} />
                色卡条
              </Button>
            </>
          ) : (
            <>
              <span className="text-[11.5px] font-mono text-[var(--text-secondary)] px-2 tabular-nums">
                {Math.round(camera.zoom * 100)}%
              </span>
              <Button
                variant="ghost"
                size="xs"
                onClick={() =>
                  handleCameraChange(
                    computeFitCamera(activeDocument.nodes, viewportWidth, 720),
                    true,
                  )
                }
                title="适配全部画布内容"
              >
                <Maximize2 size={13} />
                适配
              </Button>
              <Button
                variant="ghost"
                size="xs"
                onClick={() =>
                  mutateDocument(
                    (doc) => tidyNodesInFreeform(doc, selectedNodeIDs, assetsByID),
                    { recordHistory: true, immediateSave: true },
                  )
                }
                title="一键整理选中项或整板对齐"
              >
                <LayoutGrid size={13} />
                一键整理
              </Button>
              <Button variant="ghost" size="icon" disabled={past.length === 0} onClick={undo} title="撤销 (⌘Z)">
                <Undo2 size={14} />
              </Button>
              <Button variant="ghost" size="icon" disabled={future.length === 0} onClick={redo} title="重做 (⇧⌘Z)">
                <Redo2 size={14} />
              </Button>
            </>
          )}
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
            title="设为顶部快速采集浮窗的默认活跃情绪板"
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
            title="开启离线保留，防止缓存 LRU 自动清理本板原图"
          >
            <CloudDownload size={13} />
            <span className="hidden md:inline">离线</span>
          </Button>

          <Button
            variant="secondary"
            size="xs"
            active={candidateDrawerOpen}
            onClick={() => setCandidateDrawerOpen((v) => !v)}
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

      {/* Main Split: Dual-Mode Canvas + Collapsible Candidate Pool Drawer */}
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
          onCameraChange={handleCameraChange}
          onViewportWidthChange={setViewportWidth}
          onSelectNodes={setSelectedNodeIDs}
          onToggleSelectNode={toggleSelectNode}
          onClearSelection={clearNodeSelection}
          onCommitDocument={mutateDocument}
          onUndo={undo}
          onRedo={redo}
          onTriggerSwap={(nodeID) => {
            setSwappingNodeID(nodeID);
            setCandidateDrawerOpen(true);
          }}
          onOpenQuickLook={(asset) => openQuickLook(asset.id)}
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
          document={activeDocument}
          assetsByID={assetsByID}
          allLibraryAssets={allLibraryAssets}
          cacheBustVersion={cacheBustVersion}
          swappingNodeID={swappingNodeID}
          candidatePool={candidatePool}
          loadingCandidates={loadingCandidates}
          onClose={() => setCandidateDrawerOpen(false)}
          onCancelSwap={() => setSwappingNodeID(null)}
          onRefreshCandidates={(seedID) => void loadReplacementCandidates(seedID, 32)}
          onSwapWithAsset={(nodeID, newAssetID) => void swapNodeAsset(nodeID, newAssetID)}
          onAppendAsset={(assetID) => void addAssetsToBoard(activeDocument.id, [assetID], null)}
        />
      </div>

      {/* Export Modal (High-DPI PNG/JPG + Offline .charkleboard Figma Bridge) */}
      <ExportBoardModal
        open={exportModalOpen}
        onClose={handleCloseExportModal}
        document={activeDocument}
        containerWidth={viewportWidth}
      />

      {/* Jev Box Dialog 1: Semantic Crop Prompt */}
      <ModalShell
        open={Boolean(semanticCropTarget)}
        onClose={handleCloseSemanticCrop}
        width="sm"
        title="一句话语义裁切 (Jev Box)"
        subtitle="描述画面中想要聚焦的局部细节，自动写入非破坏性裁切框"
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
        title="按参考图匹配区域 (Jev Box)"
        subtitle="选择一张参考素材，在当前卡片中定位相似局部并自动裁切"
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
        title="指物精准批注 (Pinpoint Callout)"
        subtitle="自动定位画面中的目标点，并生成便签与锚点连线"
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
