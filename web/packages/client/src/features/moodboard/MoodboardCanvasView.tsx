import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  freezeIntoFreeform,
  isAutoEditorialMode,
  reflowNodesInsideGroupFrame,
} from '@charkle/shared';
import type {
  AssetRecord,
  BoardConnector,
  BoardNode,
  BoardPoint,
  BoardRect,
  ConnectorAnchor,
  ConnectorStyle,
  GroupTint,
  InkStroke,
  InkStrokePoint,
  MoodboardDocument,
  NormalizedCropRect,
  NoteStyle,
  UUID,
} from '@charkle/shared';
import { stopAllHoverPreviews } from '../../components/HoverMediaPreview';
import { isEditableElement } from '../capture/captureUtils';
import { ConnectorLayer } from './ConnectorLayer';
import type { PendingConnectorPreview } from './ConnectorLayer';
import {
  FloatingToolDock,
  FreeformZoomControls,
  SelectedConnectorBar,
  SelectedTransformBar,
} from './FloatingToolDock';
import { InkLayer, InkPenControlsPill } from './InkLayer';
import {
  AssetNodeView,
  BoardPaletteHeaderStrip,
  GroupFrameNodeView,
  NoteNodeView,
  PaletteStripNodeView,
} from './NodeViews';
import {
  clampZoom,
  computeFitCamera,
  computeResizedFrame,
  computeSnapDelta,
  findNodesInsideGroupFrame,
  getNodeMinSize,
  hitTestInkStroke,
  rectsIntersect,
  screenToWorld,
  snapRotationDegrees,
  zoomCameraAtScreenPoint,
} from './geometry';
import type { CameraState, MoodboardTool, ResizeHandle } from './geometry';

export interface MoodboardCanvasViewProps {
  document: MoodboardDocument;
  assetsByID: Record<UUID, AssetRecord>;
  cacheBustVersion: number;
  selectedNodeIDs: Set<UUID>;
  swappingNodeID: UUID | null;
  canUndo: boolean;
  canRedo: boolean;
  camera: CameraState;
  tidyAnimating?: boolean;
  drawerOpen?: boolean;
  onCameraChange: (next: CameraState, persist?: boolean) => void;
  onViewportChange?: (size: { width: number; height: number }) => void;
  onSelectNodes: (ids: Iterable<UUID>) => void;
  onToggleSelectNode: (id: UUID, multi: boolean) => void;
  onClearSelection: () => void;
  onCommitDocument: (
    updater: (doc: MoodboardDocument) => MoodboardDocument,
    options?: { recordHistory?: boolean; immediateSave?: boolean },
  ) => void;
  onTidyBoard: () => void;
  onUndo: () => void;
  onRedo: () => void;
  onTriggerSwap: (nodeID: UUID) => void;
  onOpenQuickLook: (asset: AssetRecord) => void;
  onCopyHex: (hex: string) => void;
  onSearchColor: (hex: string) => void;
  onOpenExport: () => void;
  onDropExternalFiles: (files: File[], worldPoint: BoardPoint | null) => void;
  onDropLibraryAssetIDs: (assetIDs: UUID[], worldPoint: BoardPoint | null) => void;
  onSmartFocusSubject: (nodeID: UUID, assetID: UUID) => void;
  onSemanticCropPrompt: (nodeID: UUID, assetID: UUID) => void;
  onVisualMatchCrop: (nodeID: UUID, assetID: UUID) => void;
  onCleanContentCrop: (nodeID: UUID, assetID: UUID) => void;
  onPinpointAnnotate: (nodeID: UUID, assetID: UUID) => void;
}

const ALL_RESIZE_HANDLES: ReadonlyArray<{
  handle: ResizeHandle;
  left?: string;
  right?: string;
  top?: string;
  bottom?: string;
  cursor: string;
}> = [
  { handle: 'nw', left: '-5px', top: '-5px', cursor: 'nwse-resize' },
  { handle: 'n', left: '50%', top: '-5px', cursor: 'ns-resize' },
  { handle: 'ne', right: '-5px', top: '-5px', cursor: 'nesw-resize' },
  { handle: 'e', right: '-5px', top: '50%', cursor: 'ew-resize' },
  { handle: 'se', right: '-5px', bottom: '-5px', cursor: 'nwse-resize' },
  { handle: 's', left: '50%', bottom: '-5px', cursor: 'ns-resize' },
  { handle: 'sw', left: '-5px', bottom: '-5px', cursor: 'nesw-resize' },
  { handle: 'w', left: '-5px', top: '50%', cursor: 'ew-resize' },
];

export const MoodboardCanvasView: React.FC<MoodboardCanvasViewProps> = ({
  document,
  assetsByID,
  cacheBustVersion,
  selectedNodeIDs,
  swappingNodeID,
  canUndo,
  canRedo,
  camera,
  tidyAnimating = false,
  drawerOpen = false,
  onCameraChange,
  onViewportChange,
  onSelectNodes,
  onToggleSelectNode,
  onClearSelection,
  onCommitDocument,
  onTidyBoard,
  onUndo,
  onRedo,
  onTriggerSwap,
  onOpenQuickLook,
  onCopyHex,
  onSearchColor,
  onOpenExport,
  onDropExternalFiles,
  onDropLibraryAssetIDs,
  onSmartFocusSubject,
  onSemanticCropPrompt,
  onVisualMatchCrop,
  onCleanContentCrop,
  onPinpointAnnotate,
}) => {
  const stageRef = useRef<HTMLDivElement | null>(null);
  const [viewport, setViewport] = useState({ width: 1120, height: 740 });
  const [viewportMeasured, setViewportMeasured] = useState(false);

  const [activeTool, setActiveTool] = useState<MoodboardTool>('select');
  const [selectedConnectorID, setSelectedConnectorID] = useState<UUID | null>(null);
  const [croppingNodeID, setCroppingNodeID] = useState<UUID | null>(null);
  const [spacePressed, setSpacePressed] = useState(false);
  const [isDropTargeted, setIsDropTargeted] = useState(false);
  const [prefersReducedMotion, setPrefersReducedMotion] = useState(false);
  const spacePannedRef = useRef(false);
  const upgradedLegacyRef = useRef<Set<UUID>>(new Set());

  useEffect(() => {
    if (typeof window === 'undefined' || !window.matchMedia) return;
    const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
    const sync = () => setPrefersReducedMotion(mq.matches);
    sync();
    mq.addEventListener('change', sync);
    return () => mq.removeEventListener('change', sync);
  }, []);

  // Live Freeform interaction overrides (1:1 pointer tracking, zero undo spam per frame)
  const [liveFrames, setLiveFrames] = useState<Record<UUID, BoardRect>>({});
  const [liveRotations, setLiveRotations] = useState<Record<UUID, number>>({});
  const [snapGuides, setSnapGuides] = useState<{ x: number[]; y: number[] }>({ x: [], y: [] });
  const [marqueeRect, setMarqueeRect] = useState<BoardRect | null>(null);

  // Connector tool & Ink pen state
  const [pendingConnector, setPendingConnector] = useState<PendingConnectorPreview | null>(null);
  const [connectorStyle, setConnectorStyle] = useState<ConnectorStyle>('curved');
  const [inkColorHex, setInkColorHex] = useState('#D95D48');
  const [inkLineWidth, setInkLineWidth] = useState(3.5);
  const [inkOpacity, setInkOpacity] = useState(0.92);
  const [activeInkPoints, setActiveInkPoints] = useState<InkStrokePoint[]>([]);

  // Refs for active pointer gestures
  const panRef = useRef<{ startClientX: number; startClientY: number; startCam: CameraState } | null>(null);
  const nodeDragRef = useRef<{
    primaryID: UUID;
    movingIDs: UUID[];
    startFrames: Record<UUID, BoardRect>;
    startWorld: BoardPoint;
  } | null>(null);
  const resizeRef = useRef<{
    node: BoardNode;
    handle: ResizeHandle;
    startWorld: BoardPoint;
    reflowChildren: BoardNode[];
  } | null>(null);
  const rotateRef = useRef<{
    node: BoardNode;
    centerWorld: BoardPoint;
    startPointerAngle: number;
    startDegrees: number;
  } | null>(null);
  const marqueeRef = useRef<{ startWorld: BoardPoint } | null>(null);
  const inkDrawingRef = useRef(false);

  // Measure viewport cleanly via ResizeObserver
  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const update = () => {
      const w = Math.max(320, Math.floor(el.clientWidth));
      const h = Math.max(240, Math.floor(el.clientHeight));
      setViewport((prev) =>
        Math.abs(prev.width - w) >= 2 || Math.abs(prev.height - h) >= 2 ? { width: w, height: h } : prev,
      );
      setViewportMeasured(true);
      onViewportChange?.({ width: w, height: h });
    };
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => ro.disconnect();
  }, [onViewportChange]);

  // Silently freeze any legacy autoEditorial board into Freeform on open with zero visual jump
  useEffect(() => {
    if (!viewportMeasured) return;
    if (!isAutoEditorialMode(document.mode)) return;
    if (upgradedLegacyRef.current.has(document.id)) return;

    upgradedLegacyRef.current.add(document.id);
    const frozen = freezeIntoFreeform(document, Math.max(640, viewport.width), assetsByID);
    const fitCam = computeFitCamera(frozen.nodes, viewport.width, viewport.height, 64, 76, 108);
    onCameraChange(fitCam, false);
    onCommitDocument(
      () => ({
        ...frozen,
        viewportCenter: { x: fitCam.centerX, y: fitCam.centerY },
        viewportZoom: fitCam.zoom,
      }),
      { recordHistory: false, immediateSave: true },
    );
  }, [
    document,
    viewportMeasured,
    viewport.width,
    viewport.height,
    assetsByID,
    onCameraChange,
    onCommitDocument,
  ]);

  const showTopPaletteStrip =
    (document.mode.type === 'autoEditorial' ? document.mode.config.showPaletteStrip : true) &&
    document.extractedPalette.length > 0;

  // Effective displayed node frames (Freeform frames + live pointer drag overrides)
  const effectiveNodes = useMemo(() => {
    return document.nodes.map((node) => {
      const frame = liveFrames[node.id] ?? node.frame;
      const rotationDegrees = liveRotations[node.id] ?? node.rotationDegrees;
      return { ...node, frame, rotationDegrees };
    });
  }, [document.nodes, liveFrames, liveRotations]);

  const effectiveNodesByID = useMemo(() => {
    const map = new Map<UUID, BoardNode>();
    for (const n of effectiveNodes) map.set(n.id, n);
    return map;
  }, [effectiveNodes]);

  // Sorted nodes for z-index layering (groupFrames always beneath non-group nodes)
  const zSortedNodes = useMemo(() => {
    return [...effectiveNodes].sort((a, b) => {
      const aGroup = a.kind.type === 'groupFrame' ? 0 : 1;
      const bGroup = b.kind.type === 'groupFrame' ? 0 : 1;
      if (aGroup !== bGroup) return aGroup - bGroup;
      if (a.zIndex !== b.zIndex) return a.zIndex - b.zIndex;
      return a.editorialOrder - b.editorialOrder;
    });
  }, [effectiveNodes]);

  const selectedNodes = useMemo(
    () => document.nodes.filter((n) => selectedNodeIDs.has(n.id)),
    [document.nodes, selectedNodeIDs],
  );

  const selectedConnector = useMemo(
    () =>
      selectedConnectorID
        ? document.connectors.find((c) => c.id === selectedConnectorID) ?? null
        : null,
    [document.connectors, selectedConnectorID],
  );

  const activeConnectorStyle = selectedConnector ? selectedConnector.style : connectorStyle;

  const handleChangeConnectorStyle = useCallback(
    (nextStyle: ConnectorStyle) => {
      setConnectorStyle(nextStyle);
      if (selectedConnectorID) {
        onCommitDocument((doc) => ({
          ...doc,
          connectors: doc.connectors.map((c) =>
            c.id === selectedConnectorID
              ? { ...c, style: nextStyle, updatedAt: new Date().toISOString() }
              : c,
          ),
        }));
      }
    },
    [selectedConnectorID, onCommitDocument],
  );

  // Node mutations
  const mutateNode = useCallback(
    (nodeID: UUID, updater: (node: BoardNode) => BoardNode, recordHistory = true) => {
      const now = new Date().toISOString();
      onCommitDocument(
        (doc) => ({
          ...doc,
          nodes: doc.nodes.map((n) => (n.id === nodeID ? { ...updater(n), updatedAt: now } : n)),
        }),
        { recordHistory },
      );
    },
    [onCommitDocument],
  );

  const deleteNodes = useCallback(
    (ids: ReadonlySet<UUID>) => {
      if (ids.size === 0) return;
      onCommitDocument(
        (doc) => ({
          ...doc,
          nodes: doc.nodes.filter((n) => !ids.has(n.id)),
          connectors: doc.connectors.filter(
            (c) => !ids.has(c.fromNodeID) && !ids.has(c.toNodeID),
          ),
        }),
        { recordHistory: true, immediateSave: true },
      );
      onClearSelection();
    },
    [onCommitDocument, onClearSelection],
  );

  const rotateSelected = useCallback(
    (delta: number) => {
      const unlocked = selectedNodes.filter((n) => !n.isLocked);
      if (unlocked.length === 0) return;
      const ids = new Set(unlocked.map((n) => n.id));
      onCommitDocument((doc) => ({
        ...doc,
        nodes: doc.nodes.map((n) =>
          ids.has(n.id) ? { ...n, rotationDegrees: ((n.rotationDegrees + delta) % 360 + 360) % 360 } : n,
        ),
      }));
    },
    [selectedNodes, onCommitDocument],
  );

  const flipSelected = useCallback(
    (axis: 'h' | 'v') => {
      const unlocked = selectedNodes.filter((n) => !n.isLocked);
      if (unlocked.length === 0) return;
      const ids = new Set(unlocked.map((n) => n.id));
      onCommitDocument((doc) => ({
        ...doc,
        nodes: doc.nodes.map((n) => {
          if (!ids.has(n.id)) return n;
          return axis === 'h'
            ? { ...n, flipHorizontal: !n.flipHorizontal }
            : { ...n, flipVertical: !n.flipVertical };
        }),
      }));
    },
    [selectedNodes, onCommitDocument],
  );

  const shiftZIndex = useCallback(
    (direction: 'front' | 'back') => {
      if (selectedNodeIDs.size === 0) return;
      onCommitDocument((doc) => {
        const zs = doc.nodes.map((n) => n.zIndex);
        const maxZ = zs.length > 0 ? Math.max(...zs) : 0;
        const minZ = zs.length > 0 ? Math.min(...zs) : 0;
        return {
          ...doc,
          nodes: doc.nodes.map((n) =>
            selectedNodeIDs.has(n.id)
              ? { ...n, zIndex: direction === 'front' ? maxZ + 1 : minZ - 1 }
              : n,
          ),
        };
      });
    },
    [selectedNodeIDs, onCommitDocument],
  );

  const toggleLockSelected = useCallback(() => {
    if (selectedNodes.length === 0) return;
    const allLocked = selectedNodes.every((n) => n.isLocked);
    const ids = new Set(selectedNodes.map((n) => n.id));
    onCommitDocument((doc) => ({
      ...doc,
      nodes: doc.nodes.map((n) => (ids.has(n.id) ? { ...n, isLocked: !allLocked } : n)),
    }));
  }, [selectedNodes, onCommitDocument]);

  const resetSelectedCrops = useCallback(() => {
    const ids = new Set(selectedNodes.map((n) => n.id));
    onCommitDocument((doc) => ({
      ...doc,
      nodes: doc.nodes.map((n) =>
        ids.has(n.id) && n.kind.type === 'assetRef'
          ? { ...n, kind: { ...n.kind, crop: null } }
          : n,
      ),
    }));
  }, [selectedNodes, onCommitDocument]);

  // Add new nodes centered in Freeform camera world coordinates
  const spawnPoint = useCallback((): BoardPoint => {
    return { x: camera.centerX, y: camera.centerY };
  }, [camera.centerX, camera.centerY]);

  const handleAddNote = useCallback(() => {
    const pt = spawnPoint();
    const now = new Date().toISOString();
    const maxOrder = document.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
    const maxZ = document.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
    const newNode: BoardNode = {
      id: crypto.randomUUID().toUpperCase(),
      kind: { type: 'note', title: '策展笔记', text: '', style: 'warm', fontSize: 14 },
      frame: { x: pt.x - 130, y: pt.y - 80, width: 260, height: 170 },
      zIndex: maxZ + 1,
      rotationDegrees: 0,
      flipHorizontal: false,
      flipVertical: false,
      isLocked: false,
      editorialOrder: maxOrder + 1,
      updatedAt: now,
    };
    onCommitDocument((doc) => ({ ...doc, nodes: [...doc.nodes, newNode] }), {
      recordHistory: true,
      immediateSave: true,
    });
    onSelectNodes([newNode.id]);
    setSelectedConnectorID(null);
  }, [spawnPoint, document.nodes, onCommitDocument, onSelectNodes]);

  const handleAddGroupFrame = useCallback(() => {
    const pt = spawnPoint();
    const now = new Date().toISOString();
    const maxOrder = document.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
    const minZ = document.nodes.reduce((m, n) => Math.min(m, n.zIndex), 0);
    const newNode: BoardNode = {
      id: crypto.randomUUID().toUpperCase(),
      kind: { type: 'groupFrame', title: '氛围分区', tint: 'sand' },
      frame: { x: pt.x - 240, y: pt.y - 160, width: 480, height: 320 },
      zIndex: minZ - 1,
      rotationDegrees: 0,
      flipHorizontal: false,
      flipVertical: false,
      isLocked: false,
      editorialOrder: maxOrder + 1,
      updatedAt: now,
    };
    onCommitDocument((doc) => ({ ...doc, nodes: [...doc.nodes, newNode] }), {
      recordHistory: true,
      immediateSave: true,
    });
    onSelectNodes([newNode.id]);
    setSelectedConnectorID(null);
  }, [spawnPoint, document.nodes, onCommitDocument, onSelectNodes]);

  const handleAddPaletteStrip = useCallback(() => {
    const pt = spawnPoint();
    const now = new Date().toISOString();
    const maxOrder = document.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
    const maxZ = document.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
    const newNode: BoardNode = {
      id: crypto.randomUUID().toUpperCase(),
      kind: {
        type: 'paletteStrip',
        colors: document.extractedPalette,
        autoSyncWithBoard: true,
      },
      frame: { x: pt.x - 220, y: pt.y - 34, width: 440, height: 68 },
      zIndex: maxZ + 1,
      rotationDegrees: 0,
      flipHorizontal: false,
      flipVertical: false,
      isLocked: false,
      editorialOrder: maxOrder + 1,
      updatedAt: now,
    };
    onCommitDocument((doc) => ({ ...doc, nodes: [...doc.nodes, newNode] }), {
      recordHistory: true,
      immediateSave: true,
    });
    onSelectNodes([newNode.id]);
    setSelectedConnectorID(null);
  }, [spawnPoint, document.nodes, document.extractedPalette, onCommitDocument, onSelectNodes]);

  // Keyboard shortcuts (instant state changes, zero sluggish animation)
  useEffect(() => {
    const hasOpenModalDialog = () =>
      typeof window !== 'undefined' &&
      Boolean(window.document.querySelector('[role="dialog"][aria-modal="true"]'));

    const onKeyDown = (e: KeyboardEvent) => {
      if (isEditableElement(e.target)) return;
      if (hasOpenModalDialog()) return;

      const meta = e.metaKey || e.ctrlKey;
      const lower = e.key.toLowerCase();

      if (meta && lower === 'z') {
        e.preventDefault();
        if (e.shiftKey) onRedo();
        else onUndo();
        return;
      }

      if (meta && lower === 'a') {
        e.preventDefault();
        onSelectNodes(document.nodes.map((n) => n.id));
        setSelectedConnectorID(null);
        return;
      }

      if (e.key === 'Escape') {
        if (croppingNodeID) {
          setCroppingNodeID(null);
          return;
        }
        if (pendingConnector) {
          setPendingConnector(null);
          return;
        }
        if (activeTool !== 'select') {
          setActiveTool('select');
          return;
        }
        onClearSelection();
        setSelectedConnectorID(null);
        return;
      }

      if (e.key === 'Backspace' || e.key === 'Delete') {
        if (selectedConnectorID) {
          e.preventDefault();
          const cid = selectedConnectorID;
          setSelectedConnectorID(null);
          onCommitDocument((doc) => ({
            ...doc,
            connectors: doc.connectors.filter((c) => c.id !== cid),
          }));
          return;
        }
        if (selectedNodeIDs.size > 0) {
          e.preventDefault();
          deleteNodes(selectedNodeIDs);
          return;
        }
      }

      if (e.code === 'Space' && !e.repeat) {
        e.preventDefault();
        spacePannedRef.current = false;
        setSpacePressed(true);
        return;
      }

      if (!meta && selectedNodes.length > 0) {
        if (lower === 'r' && !e.shiftKey) {
          e.preventDefault();
          rotateSelected(90);
          return;
        }
        if (lower === 'r' && e.shiftKey) {
          e.preventDefault();
          rotateSelected(-90);
          return;
        }
        if (lower === 'h' && e.shiftKey) {
          e.preventDefault();
          flipSelected('h');
          return;
        }
        if (lower === 'v' && e.shiftKey) {
          e.preventDefault();
          flipSelected('v');
          return;
        }
      }

      if (!meta && !e.shiftKey) {
        if (lower === 'v') setActiveTool('select');
        else if (lower === 'h') setActiveTool('pan');
        else if (lower === 'c') setActiveTool('connector');
        else if (lower === 'p') setActiveTool('pen');
        else if (lower === 'e') setActiveTool('eraser');
      }
    };

    const onKeyUp = (e: KeyboardEvent) => {
      if (hasOpenModalDialog()) return;
      if (e.code === 'Space') {
        setSpacePressed(false);
        if (
          !spacePannedRef.current &&
          selectedNodes.length === 1 &&
          selectedNodes[0].kind.type === 'assetRef'
        ) {
          const asset = assetsByID[selectedNodes[0].kind.assetID];
          if (asset) {
            onOpenQuickLook(asset);
          }
        }
      }
    };

    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keyup', onKeyUp);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keyup', onKeyUp);
    };
  }, [
    activeTool,
    croppingNodeID,
    pendingConnector,
    selectedConnectorID,
    selectedNodeIDs,
    selectedNodes,
    document.nodes,
    assetsByID,
    onUndo,
    onRedo,
    onSelectNodes,
    onClearSelection,
    onCommitDocument,
    deleteNodes,
    rotateSelected,
    flipSelected,
    onOpenQuickLook,
  ]);

  // Freeform Wheel / Pinch Zoom & Trackpad Pan
  const handleWheel = useCallback(
    (e: React.WheelEvent<HTMLDivElement>) => {
      e.preventDefault();
      stopAllHoverPreviews();
      const rect = stageRef.current?.getBoundingClientRect();
      if (!rect) return;
      const pointerScreen = { x: e.clientX - rect.left, y: e.clientY - rect.top };

      if (e.ctrlKey || e.metaKey) {
        const factor = Math.exp(-e.deltaY * 0.005);
        const next = zoomCameraAtScreenPoint(
          camera,
          camera.zoom * factor,
          pointerScreen,
          viewport.width,
          viewport.height,
        );
        onCameraChange(next, false);
      } else {
        onCameraChange(
          {
            ...camera,
            centerX: camera.centerX + e.deltaX / camera.zoom,
            centerY: camera.centerY + e.deltaY / camera.zoom,
          },
          false,
        );
      }
    },
    [camera, viewport.width, viewport.height, onCameraChange],
  );

  // Convert client pointer to Freeform world point
  const clientToWorld = useCallback(
    (clientX: number, clientY: number): BoardPoint => {
      const rect = stageRef.current?.getBoundingClientRect();
      const sx = rect ? clientX - rect.left : clientX;
      const sy = rect ? clientY - rect.top : clientY;
      return screenToWorld({ x: sx, y: sy }, camera, viewport.width, viewport.height);
    },
    [camera, viewport.width, viewport.height],
  );

  // Stage pointer handlers (Freeform pan, marquee, pen, eraser)
  const handleStagePointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    const targetEl = e.target instanceof Element ? e.target : null;
    if (
      targetEl?.closest(
        'button, input, textarea, select, a, [role="toolbar"], [role="radiogroup"], [role="menu"], [data-canvas-hud="true"]',
      )
    ) {
      return;
    }

    stopAllHoverPreviews();

    const isMiddleButton = e.button === 1;
    if (isMiddleButton || spacePressed || activeTool === 'pan') {
      e.preventDefault();
      if (spacePressed) spacePannedRef.current = true;
      e.currentTarget.setPointerCapture(e.pointerId);
      panRef.current = {
        startClientX: e.clientX,
        startClientY: e.clientY,
        startCam: { ...camera },
      };
      return;
    }

    if (e.button !== 0) return;

    const worldPt = clientToWorld(e.clientX, e.clientY);

    if (activeTool === 'pen') {
      e.preventDefault();
      e.currentTarget.setPointerCapture(e.pointerId);
      inkDrawingRef.current = true;
      setActiveInkPoints([{ x: worldPt.x, y: worldPt.y, pressure: e.pressure || 0.5 }]);
      return;
    }

    if (activeTool === 'eraser') {
      e.preventDefault();
      const hitRadius = 18 / Math.max(0.25, camera.zoom);
      const hitStroke = document.inkStrokes.find((s) =>
        hitTestInkStroke(worldPt, s.points, hitRadius),
      );
      if (hitStroke) {
        onCommitDocument((doc) => ({
          ...doc,
          inkStrokes: doc.inkStrokes.filter((s) => s.id !== hitStroke.id),
        }));
      }
      return;
    }

    // Background click in select mode -> start marquee selection
    onClearSelection();
    setSelectedConnectorID(null);
    setCroppingNodeID(null);
    e.currentTarget.setPointerCapture(e.pointerId);
    marqueeRef.current = { startWorld: worldPt };
    setMarqueeRect({ x: worldPt.x, y: worldPt.y, width: 0, height: 0 });
  };

  const handleStagePointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    // 1. Panning
    if (panRef.current) {
      const dx = (e.clientX - panRef.current.startClientX) / panRef.current.startCam.zoom;
      const dy = (e.clientY - panRef.current.startClientY) / panRef.current.startCam.zoom;
      onCameraChange(
        {
          ...panRef.current.startCam,
          centerX: panRef.current.startCam.centerX - dx,
          centerY: panRef.current.startCam.centerY - dy,
        },
        false,
      );
      return;
    }

    const worldPt = clientToWorld(e.clientX, e.clientY);

    // 2. Pending connector drag
    if (pendingConnector) {
      setPendingConnector((prev) => (prev ? { ...prev, cursorWorld: worldPt } : null));
      return;
    }

    // 3. Ink Pen drawing
    if (inkDrawingRef.current) {
      setActiveInkPoints((prev) => {
        const last = prev[prev.length - 1];
        if (last && Math.hypot(worldPt.x - last.x, worldPt.y - last.y) < 2.2 / camera.zoom) {
          return prev;
        }
        return [...prev, { x: worldPt.x, y: worldPt.y, pressure: e.pressure || 0.5 }];
      });
      return;
    }

    // 4. Node drag with smart alignment snap guides
    if (nodeDragRef.current) {
      const drag = nodeDragRef.current;
      let dx = worldPt.x - drag.startWorld.x;
      let dy = worldPt.y - drag.startWorld.y;

      const movingSet = new Set(drag.movingIDs);
      const primaryStart = drag.startFrames[drag.primaryID];
      if (primaryStart && !e.altKey) {
        const candidate: BoardRect = {
          x: primaryStart.x + dx,
          y: primaryStart.y + dy,
          width: primaryStart.width,
          height: primaryStart.height,
        };
        const siblingRects = document.nodes
          .filter((n) => !movingSet.has(n.id))
          .map((n) => n.frame);
        const snap = computeSnapDelta(candidate, siblingRects, camera.zoom, 6);
        dx += snap.dx;
        dy += snap.dy;
        setSnapGuides({ x: snap.guidesX, y: snap.guidesY });
      } else {
        setSnapGuides({ x: [], y: [] });
      }

      const nextFrames: Record<UUID, BoardRect> = {};
      for (const id of drag.movingIDs) {
        const sf = drag.startFrames[id];
        if (sf) {
          nextFrames[id] = { x: sf.x + dx, y: sf.y + dy, width: sf.width, height: sf.height };
        }
      }
      setLiveFrames(nextFrames);
      return;
    }

    // 5. Node 8-handle resize (+ live group frame auto-reflow!)
    if (resizeRef.current) {
      const rs = resizeRef.current;
      const dx = worldPt.x - rs.startWorld.x;
      const dy = worldPt.y - rs.startWorld.y;
      const lockAspect = rs.node.kind.type === 'assetRef' ? !e.shiftKey : e.shiftKey;
      const nextFrame = computeResizedFrame(
        rs.node.frame,
        rs.handle,
        dx,
        dy,
        rs.node.rotationDegrees,
        getNodeMinSize(rs.node.kind.type),
        lockAspect,
      );

      const updates: Record<UUID, BoardRect> = { [rs.node.id]: nextFrame };
      if (rs.node.kind.type === 'groupFrame' && rs.reflowChildren.length > 0) {
        const reflowed = reflowNodesInsideGroupFrame(nextFrame, rs.reflowChildren, assetsByID);
        Object.assign(updates, reflowed);
      }
      setLiveFrames(updates);
      return;
    }

    // 6. Node rotation
    if (rotateRef.current) {
      const rt = rotateRef.current;
      const angleNow =
        (Math.atan2(worldPt.y - rt.centerWorld.y, worldPt.x - rt.centerWorld.x) * 180) / Math.PI;
      const raw = rt.startDegrees + (angleNow - rt.startPointerAngle);
      const snapped = snapRotationDegrees(raw, e.shiftKey);
      setLiveRotations({ [rt.node.id]: snapped });
      return;
    }

    // 7. Marquee selection
    if (marqueeRef.current) {
      const sw = marqueeRef.current.startWorld;
      const rect: BoardRect = {
        x: Math.min(sw.x, worldPt.x),
        y: Math.min(sw.y, worldPt.y),
        width: Math.abs(worldPt.x - sw.x),
        height: Math.abs(worldPt.y - sw.y),
      };
      setMarqueeRect(rect);
      const hits = document.nodes.filter((n) => rectsIntersect(rect, n.frame)).map((n) => n.id);
      onSelectNodes(hits);
    }
  };

  const handleStagePointerUp = (e: React.PointerEvent<HTMLDivElement>) => {
    if (panRef.current) {
      panRef.current = null;
      onCameraChange(camera, true);
      return;
    }

    if (inkDrawingRef.current) {
      inkDrawingRef.current = false;
      if (activeInkPoints.length >= 2) {
        const maxZ = document.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
        const stroke: InkStroke = {
          id: crypto.randomUUID().toUpperCase(),
          points: activeInkPoints,
          colorHex: inkColorHex,
          lineWidth: inkLineWidth,
          opacity: inkOpacity,
          zIndex: maxZ + 10,
          createdAt: new Date().toISOString(),
        };
        onCommitDocument((doc) => ({
          ...doc,
          inkStrokes: [...doc.inkStrokes, stroke],
        }));
      }
      setActiveInkPoints([]);
      return;
    }

    if (pendingConnector) {
      const worldPt = clientToWorld(e.clientX, e.clientY);
      const targetNode = [...zSortedNodes]
        .reverse()
        .find(
          (n) =>
            n.id !== pendingConnector.fromNodeID &&
            worldPt.x >= n.frame.x &&
            worldPt.x <= n.frame.x + n.frame.width &&
            worldPt.y >= n.frame.y &&
            worldPt.y <= n.frame.y + n.frame.height,
        );
      if (targetNode) {
        // Hold Alt while dropping inside a card to create an internal normalized pinpoint anchor!
        const toNormalizedPoint = e.altKey
          ? {
              x: Math.max(
                0.05,
                Math.min(0.95, (worldPt.x - targetNode.frame.x) / Math.max(1, targetNode.frame.width)),
              ),
              y: Math.max(
                0.05,
                Math.min(0.95, (worldPt.y - targetNode.frame.y) / Math.max(1, targetNode.frame.height)),
              ),
            }
          : null;
        const newConnector: BoardConnector = {
          id: crypto.randomUUID().toUpperCase(),
          fromNodeID: pendingConnector.fromNodeID,
          fromAnchor: pendingConnector.fromAnchor,
          fromNormalizedPoint: null,
          toNodeID: targetNode.id,
          toAnchor: 'auto',
          toNormalizedPoint,
          label: null,
          colorHex: '#5C6672',
          style: connectorStyle,
          dashed: false,
          updatedAt: new Date().toISOString(),
        };
        onCommitDocument((doc) => ({
          ...doc,
          connectors: [...doc.connectors, newConnector],
        }));
        setSelectedConnectorID(newConnector.id);
      }
      setPendingConnector(null);
      return;
    }

    if (nodeDragRef.current) {
      nodeDragRef.current = null;
      const updates = { ...liveFrames };
      setLiveFrames({});
      setSnapGuides({ x: [], y: [] });
      if (Object.keys(updates).length > 0) {
        onCommitDocument((doc) => ({
          ...doc,
          nodes: doc.nodes.map((n) => (updates[n.id] ? { ...n, frame: updates[n.id] } : n)),
        }));
      }
      return;
    }

    if (resizeRef.current) {
      resizeRef.current = null;
      const updates = { ...liveFrames };
      setLiveFrames({});
      if (Object.keys(updates).length > 0) {
        onCommitDocument((doc) => ({
          ...doc,
          nodes: doc.nodes.map((n) => (updates[n.id] ? { ...n, frame: updates[n.id] } : n)),
        }));
      }
      return;
    }

    if (rotateRef.current) {
      rotateRef.current = null;
      const updates = { ...liveRotations };
      setLiveRotations({});
      if (Object.keys(updates).length > 0) {
        onCommitDocument((doc) => ({
          ...doc,
          nodes: doc.nodes.map((n) =>
            updates[n.id] !== undefined ? { ...n, rotationDegrees: updates[n.id] } : n,
          ),
        }));
      }
      return;
    }

    if (marqueeRef.current) {
      marqueeRef.current = null;
      setMarqueeRect(null);
    }
  };

  // Start dragging a node
  const handleNodePointerDown = (node: BoardNode, e: React.PointerEvent) => {
    if (e.button !== 0) return;
    if (spacePressed || activeTool === 'pan' || activeTool === 'pen' || activeTool === 'eraser') {
      return;
    }
    if (croppingNodeID === node.id) return;

    e.stopPropagation();
    stopAllHoverPreviews();
    setSelectedConnectorID(null);

    // Connector creation tool
    if (activeTool === 'connector') {
      const worldPt = clientToWorld(e.clientX, e.clientY);
      setPendingConnector({
        fromNodeID: node.id,
        fromAnchor: 'auto',
        startWorld: {
          x: node.frame.x + node.frame.width * 0.5,
          y: node.frame.y + node.frame.height * 0.5,
        },
        cursorWorld: worldPt,
        style: connectorStyle,
        dashed: false,
        colorHex: '#5C6672',
      });
      stageRef.current?.setPointerCapture(e.pointerId);
      return;
    }

    const multi = e.metaKey || e.ctrlKey || e.shiftKey;
    const willBeSelected = selectedNodeIDs.has(node.id)
      ? selectedNodeIDs
      : multi
        ? new Set([...selectedNodeIDs, node.id])
        : new Set([node.id]);
    if (!selectedNodeIDs.has(node.id) || multi) {
      onToggleSelectNode(node.id, multi);
    }

    if (node.isLocked) return;

    // Drag node(s) (+ enclosed children if dragging a GroupFrame!)
    const movingIDs = new Set<UUID>();
    for (const id of willBeSelected) {
      const target = document.nodes.find((n) => n.id === id);
      if (!target || target.isLocked) continue;
      movingIDs.add(target.id);
      if (target.kind.type === 'groupFrame') {
        for (const child of findNodesInsideGroupFrame(target, document.nodes)) {
          if (!child.isLocked) movingIDs.add(child.id);
        }
      }
    }

    const startFrames: Record<UUID, BoardRect> = {};
    for (const id of movingIDs) {
      const target = document.nodes.find((n) => n.id === id);
      if (target) startFrames[id] = { ...target.frame };
    }

    stageRef.current?.setPointerCapture(e.pointerId);
    nodeDragRef.current = {
      primaryID: node.id,
      movingIDs: Array.from(movingIDs),
      startFrames,
      startWorld: clientToWorld(e.clientX, e.clientY),
    };
  };

  // Start resizing a Freeform node (8 handles or groupFrame live side-edge reflow)
  const startResize = (node: BoardNode, handle: ResizeHandle, e: React.PointerEvent) => {
    e.stopPropagation();
    e.preventDefault();
    if (node.isLocked) return;
    stopAllHoverPreviews();
    stageRef.current?.setPointerCapture(e.pointerId);
    const reflowChildren =
      node.kind.type === 'groupFrame' ? findNodesInsideGroupFrame(node, document.nodes) : [];
    resizeRef.current = {
      node,
      handle,
      startWorld: clientToWorld(e.clientX, e.clientY),
      reflowChildren,
    };
  };

  // Start rotating a Freeform node
  const startRotate = (node: BoardNode, e: React.PointerEvent) => {
    e.stopPropagation();
    e.preventDefault();
    if (node.isLocked) return;
    stopAllHoverPreviews();
    stageRef.current?.setPointerCapture(e.pointerId);
    const centerWorld = {
      x: node.frame.x + node.frame.width * 0.5,
      y: node.frame.y + node.frame.height * 0.5,
    };
    const startWorld = clientToWorld(e.clientX, e.clientY);
    const startPointerAngle =
      (Math.atan2(startWorld.y - centerWorld.y, startWorld.x - centerWorld.x) * 180) / Math.PI;
    rotateRef.current = {
      node,
      centerWorld,
      startPointerAngle,
      startDegrees: node.rotationDegrees,
    };
  };

  // External file drop & library asset drop directly onto world coordinates
  const handleDragOver = (e: React.DragEvent) => {
    if (
      e.dataTransfer.types.includes('Files') ||
      e.dataTransfer.types.includes('application/x-charkle-asset-ids')
    ) {
      e.preventDefault();
      e.dataTransfer.dropEffect = 'copy';
      setIsDropTargeted(true);
    }
  };

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setIsDropTargeted(false);
    const dropWorld = clientToWorld(e.clientX, e.clientY);

    const rawAssetIDs = e.dataTransfer.getData('application/x-charkle-asset-ids');
    if (rawAssetIDs) {
      try {
        const ids = JSON.parse(rawAssetIDs) as UUID[];
        if (Array.isArray(ids) && ids.length > 0) {
          onDropLibraryAssetIDs(ids, dropWorld);
          return;
        }
      } catch {
        // Fall through
      }
    }

    const files = Array.from(e.dataTransfer.files);
    if (files.length > 0) {
      onDropExternalFiles(files, dropWorld);
    }
  };

  // Dot grid geometry for Freeform canvas
  const dotStepScreen = Math.max(16, Math.min(56, 28 * camera.zoom));
  const dotOffsetX =
    (((viewport.width * 0.5 - camera.centerX * camera.zoom) % dotStepScreen) + dotStepScreen) %
    dotStepScreen;
  const dotOffsetY =
    (((viewport.height * 0.5 - camera.centerY * camera.zoom) % dotStepScreen) + dotStepScreen) %
    dotStepScreen;

  // Render an individual node's inner view
  const renderNodeBody = (node: BoardNode) => {
    const isSelected = selectedNodeIDs.has(node.id);
    switch (node.kind.type) {
      case 'assetRef': {
        const assetID = node.kind.assetID;
        const asset = assetsByID[assetID];
        return (
          <AssetNodeView
            node={node}
            asset={asset}
            cacheBustVersion={cacheBustVersion}
            isSelected={isSelected}
            isSwapTarget={swappingNodeID === node.id}
            isCropping={croppingNodeID === node.id}
            onStartInlineCrop={() => setCroppingNodeID(node.id)}
            onCommitCrop={(crop: NormalizedCropRect | null) => {
              setCroppingNodeID(null);
              mutateNode(node.id, (n) =>
                n.kind.type === 'assetRef' ? { ...n, kind: { ...n.kind, crop } } : n,
              );
            }}
            onCancelCrop={() => setCroppingNodeID(null)}
            onToggleHero={() =>
              mutateNode(node.id, (n) =>
                n.kind.type === 'assetRef'
                  ? { ...n, kind: { ...n.kind, weight: n.kind.weight >= 2 ? 1 : 2 } }
                  : n,
              )
            }
            onTriggerSwap={() => onTriggerSwap(node.id)}
            onOpenQuickLook={() => {
              if (asset) onOpenQuickLook(asset);
            }}
            onSmartFocusSubject={() => onSmartFocusSubject(node.id, assetID)}
            onSemanticCropPrompt={() => onSemanticCropPrompt(node.id, assetID)}
            onVisualMatchCrop={() => onVisualMatchCrop(node.id, assetID)}
            onCleanContentCrop={() => onCleanContentCrop(node.id, assetID)}
            onPinpointAnnotate={() => onPinpointAnnotate(node.id, assetID)}
            onRotateBy={(delta) =>
              mutateNode(node.id, (n) => ({
                ...n,
                rotationDegrees: ((n.rotationDegrees + delta) % 360 + 360) % 360,
              }))
            }
            onFlipHorizontal={() =>
              mutateNode(node.id, (n) => ({ ...n, flipHorizontal: !n.flipHorizontal }))
            }
            onFlipVertical={() =>
              mutateNode(node.id, (n) => ({ ...n, flipVertical: !n.flipVertical }))
            }
            onToggleLock={() =>
              mutateNode(node.id, (n) => ({ ...n, isLocked: !n.isLocked }))
            }
            onDelete={() => deleteNodes(new Set([node.id]))}
          />
        );
      }

      case 'note':
        return (
          <NoteNodeView
            node={node}
            isSelected={isSelected}
            onUpdate={(title, text, style: NoteStyle, fontSize: number) =>
              mutateNode(
                node.id,
                (n) =>
                  n.kind.type === 'note'
                    ? { ...n, kind: { type: 'note', title, text, style, fontSize } }
                    : n,
                false,
              )
            }
            onDelete={() => deleteNodes(new Set([node.id]))}
          />
        );

      case 'groupFrame': {
        const enclosed = findNodesInsideGroupFrame(node, document.nodes);
        return (
          <GroupFrameNodeView
            node={node}
            enclosedCount={enclosed.length}
            isSelected={isSelected}
            onUpdate={(title, tint: GroupTint) =>
              mutateNode(
                node.id,
                (n) =>
                  n.kind.type === 'groupFrame'
                    ? { ...n, kind: { type: 'groupFrame', title, tint } }
                    : n,
                false,
              )
            }
            onAutoReflow={() => {
              const reflowed = reflowNodesInsideGroupFrame(node.frame, enclosed, assetsByID);
              onCommitDocument((doc) => ({
                ...doc,
                nodes: doc.nodes.map((n) => (reflowed[n.id] ? { ...n, frame: reflowed[n.id] } : n)),
              }));
            }}
            onDelete={() => deleteNodes(new Set([node.id]))}
            onSideResizeStart={(edge, ev) => startResize(node, edge, ev)}
          />
        );
      }

      case 'paletteStrip':
        return (
          <PaletteStripNodeView
            node={node}
            boardPalette={document.extractedPalette}
            isSelected={isSelected}
            onToggleAutoSync={() =>
              mutateNode(node.id, (n) =>
                n.kind.type === 'paletteStrip'
                  ? { ...n, kind: { ...n.kind, autoSyncWithBoard: !n.kind.autoSyncWithBoard } }
                  : n,
              )
            }
            onCopyHex={onCopyHex}
            onSearchColor={onSearchColor}
            onDelete={() => deleteNodes(new Set([node.id]))}
          />
        );
    }
  };

  const stageCursor =
    panRef.current
      ? 'grabbing'
      : spacePressed || activeTool === 'pan'
        ? 'grab'
        : activeTool === 'pen' || activeTool === 'connector' || activeTool === 'eraser'
          ? 'crosshair'
          : 'default';

  const hasCroppedSelection = selectedNodes.some(
    (n) => n.kind.type === 'assetRef' && Boolean(n.kind.crop),
  );

  const shouldAnimateTidy = tidyAnimating && !prefersReducedMotion;

  return (
    <div
      ref={stageRef}
      onWheel={handleWheel}
      onPointerDown={handleStagePointerDown}
      onPointerMove={handleStagePointerMove}
      onPointerUp={handleStagePointerUp}
      onDragOver={handleDragOver}
      onDragLeave={() => setIsDropTargeted(false)}
      onDrop={handleDrop}
      className="relative flex-1 min-w-0 h-full overflow-hidden bg-[var(--bg-gallery)] select-none"
      style={{ cursor: stageCursor }}
    >
      {/* Unified Freeform Infinite Canvas */}
      <div className="relative w-full h-full overflow-hidden">
        {/* Calm architectural dot grid */}
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 opacity-45"
          style={{
            backgroundImage:
              'radial-gradient(circle, var(--text-tertiary) 1px, transparent 1px)',
            backgroundSize: `${dotStepScreen}px ${dotStepScreen}px`,
            backgroundPosition: `${dotOffsetX}px ${dotOffsetY}px`,
          }}
        />

        {/* Empty canvas guidance */}
        {document.nodes.length === 0 && (
          <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center text-center px-6">
            <p className="text-[13.5px] font-medium text-[var(--text-secondary)]">
              拖入图片、按 ⌘V 粘贴，或从右侧候选池添加素材
            </p>
          </div>
        )}

        {/* World Transform Plane */}
        <div
          className="absolute top-0 left-0 origin-top-left"
          style={{
            transform: `translate3d(${viewport.width * 0.5 - camera.centerX * camera.zoom}px, ${viewport.height * 0.5 - camera.centerY * camera.zoom}px, 0) scale(${camera.zoom})`,
            transition: shouldAnimateTidy
              ? 'transform var(--duration-move, 240ms) var(--ease-in-out)'
              : 'none',
          }}
        >
          {/* Nodes */}
          {zSortedNodes.map((node, idx) => {
            const isSelected = selectedNodeIDs.has(node.id);
            const showTransformHandles =
              isSelected &&
              selectedNodeIDs.size === 1 &&
              !node.isLocked &&
              activeTool === 'select' &&
              croppingNodeID !== node.id;

            return (
              <div
                key={node.id}
                onPointerDown={(e) => handleNodePointerDown(node, e)}
                className="absolute top-0 left-0"
                style={{
                  width: node.frame.width,
                  height: node.frame.height,
                  zIndex: node.kind.type === 'groupFrame' ? 1 : 10 + idx,
                  transform: `translate3d(${node.frame.x}px, ${node.frame.y}px, 0) rotate(${node.rotationDegrees}deg)`,
                  transition: shouldAnimateTidy
                    ? 'transform var(--duration-move, 240ms) var(--ease-in-out), width var(--duration-move, 240ms) var(--ease-in-out), height var(--duration-move, 240ms) var(--ease-in-out)'
                    : 'none',
                }}
              >
                {renderNodeBody(node)}

                {/* Connector anchor dots when connector tool active */}
                {activeTool === 'connector' && (
                  <>
                    {(['top', 'bottom', 'leading', 'trailing'] as const).map(
                      (anchor: ConnectorAnchor) => {
                        const posStyle: React.CSSProperties =
                          anchor === 'top'
                            ? { left: '50%', top: -6, transform: 'translateX(-50%)' }
                            : anchor === 'bottom'
                              ? { left: '50%', bottom: -6, transform: 'translateX(-50%)' }
                              : anchor === 'leading'
                                ? { left: -6, top: '50%', transform: 'translateY(-50%)' }
                                : { right: -6, top: '50%', transform: 'translateY(-50%)' };
                        return (
                          <button
                            key={anchor}
                            type="button"
                            aria-label={`从 ${anchor} 锚点连线`}
                            onPointerDown={(ev) => {
                              ev.stopPropagation();
                              const worldPt = clientToWorld(ev.clientX, ev.clientY);
                              setPendingConnector({
                                fromNodeID: node.id,
                                fromAnchor: anchor,
                                startWorld: worldPt,
                                cursorWorld: worldPt,
                                style: connectorStyle,
                                dashed: false,
                                colorHex: '#5C6672',
                              });
                              stageRef.current?.setPointerCapture(ev.pointerId);
                            }}
                            className="absolute z-40 w-3 h-3 rounded-full bg-[var(--accent)] border-2 border-white shadow-sm cursor-crosshair"
                            style={posStyle}
                          />
                        );
                      },
                    )}
                  </>
                )}

                {/* 8-Handle Resize + Top-Center Rotate Handle */}
                {showTransformHandles && (
                  <>
                    {ALL_RESIZE_HANDLES.map((h) => (
                      <div
                        key={h.handle}
                        onPointerDown={(ev) => startResize(node, h.handle, ev)}
                        className="absolute z-30 w-2.5 h-2.5 rounded-[3px] bg-white border-[1.5px] border-[var(--accent)] shadow-xs"
                        style={{
                          left: h.left,
                          right: h.right,
                          top: h.top,
                          bottom: h.bottom,
                          transform:
                            h.left === '50%'
                              ? 'translateX(-50%)'
                              : h.top === '50%'
                                ? 'translateY(-50%)'
                                : undefined,
                          cursor: h.cursor,
                        }}
                      />
                    ))}

                    {/* Rotation stem & knob (double-click resets to 0°) */}
                    <div
                      className="absolute left-1/2 -translate-x-1/2 -top-7 flex flex-col items-center z-30"
                      onPointerDown={(ev) => startRotate(node, ev)}
                      onDoubleClick={(ev) => {
                        ev.stopPropagation();
                        mutateNode(node.id, (n) => ({ ...n, rotationDegrees: 0 }));
                      }}
                      title="拖动旋转（按住 Shift 吸附 15°，双击归零）"
                    >
                      <div className="w-4.5 h-4.5 rounded-full bg-white border-[1.5px] border-[var(--accent)] shadow-xs cursor-grab active:cursor-grabbing flex items-center justify-center">
                        <span className="w-1.5 h-1.5 rounded-full bg-[var(--accent)]" />
                      </div>
                      <div className="w-px h-2.5 bg-[var(--accent)]" />
                    </div>
                  </>
                )}
              </div>
            );
          })}

          {/* Connectors Layer */}
          <div className="absolute inset-0 z-40 pointer-events-none">
            <ConnectorLayer
              connectors={document.connectors}
              nodesByID={effectiveNodesByID}
              selectedConnectorID={selectedConnectorID}
              pendingConnector={pendingConnector}
              zoom={camera.zoom}
              interactive={activeTool === 'select' || activeTool === 'connector'}
              onSelectConnector={(cid) => {
                setSelectedConnectorID(cid);
                if (cid) onClearSelection();
              }}
              onUpdateConnector={(cid, patch) => {
                onCommitDocument((doc) => ({
                  ...doc,
                  connectors: doc.connectors.map((c) =>
                    c.id === cid ? { ...c, ...patch, updatedAt: new Date().toISOString() } : c,
                  ),
                }));
              }}
              onDeleteConnector={(cid) => {
                setSelectedConnectorID(null);
                onCommitDocument((doc) => ({
                  ...doc,
                  connectors: doc.connectors.filter((c) => c.id !== cid),
                }));
              }}
            />
          </div>

          {/* Freehand Ink Annotation Layer */}
          <div className="absolute inset-0 z-50 pointer-events-none">
            <InkLayer
              strokes={document.inkStrokes}
              activeStrokePoints={activeInkPoints}
              activeColorHex={inkColorHex}
              activeLineWidth={inkLineWidth}
              activeOpacity={inkOpacity}
              eraserActive={activeTool === 'eraser'}
              onEraseStroke={(sid) => {
                onCommitDocument((doc) => ({
                  ...doc,
                  inkStrokes: doc.inkStrokes.filter((s) => s.id !== sid),
                }));
              }}
            />
          </div>

          {/* Smart Alignment Snap Guides */}
          {(snapGuides.x.length > 0 || snapGuides.y.length > 0) && (
            <svg
              className="absolute inset-0 overflow-visible pointer-events-none z-50"
              width="1"
              height="1"
            >
              {snapGuides.x.map((gx) => (
                <line
                  key={`gx-${gx}`}
                  x1={gx}
                  y1={camera.centerY - 4000}
                  x2={gx}
                  y2={camera.centerY + 4000}
                  stroke="var(--accent)"
                  strokeWidth={1 / camera.zoom}
                  strokeDasharray={`${4 / camera.zoom} ${3 / camera.zoom}`}
                />
              ))}
              {snapGuides.y.map((gy) => (
                <line
                  key={`gy-${gy}`}
                  x1={camera.centerX - 4000}
                  y1={gy}
                  x2={camera.centerX + 4000}
                  y2={gy}
                  stroke="var(--accent)"
                  strokeWidth={1 / camera.zoom}
                  strokeDasharray={`${4 / camera.zoom} ${3 / camera.zoom}`}
                />
              ))}
            </svg>
          )}

          {/* Rubber-Band Marquee Selection Box */}
          {marqueeRect && marqueeRect.width > 2 && marqueeRect.height > 2 && (
            <div
              aria-hidden="true"
              className="pointer-events-none absolute z-50 rounded-[4px] border border-[var(--accent)] bg-[var(--accent-soft)]"
              style={{
                left: marqueeRect.x,
                top: marqueeRect.y,
                width: marqueeRect.width,
                height: marqueeRect.height,
              }}
            />
          )}
        </div>
      </div>

      {/* Top Floating Board Palette Strip */}
      {showTopPaletteStrip && (
        <div className="pointer-events-none absolute top-3 left-0 right-0 z-20 flex justify-center px-4">
          <div
            data-canvas-hud="true"
            onPointerDown={(e) => e.stopPropagation()}
            className="pointer-events-auto"
          >
            <BoardPaletteHeaderStrip
              colors={document.extractedPalette}
              onCopyHex={onCopyHex}
              onSearchColor={onSearchColor}
            />
          </div>
        </div>
      )}

      {/* Bottom-Right Freeform Zoom Controls (glides smoothly clear of Candidate Pool drawer) */}
      <div
        data-canvas-hud="true"
        onPointerDown={(e) => e.stopPropagation()}
        className="absolute right-5 bottom-5 z-20 transition-transform"
        style={{
          transitionDuration: drawerOpen
            ? 'var(--duration-drawer, 300ms)'
            : 'var(--duration-exit-md, 170ms)',
          transitionTimingFunction: drawerOpen
            ? 'var(--ease-drawer, cubic-bezier(0.32, 0.72, 0, 1))'
            : 'var(--ease-out, cubic-bezier(0.23, 1, 0.32, 1))',
          transform: drawerOpen ? 'translate3d(-300px, 0, 0)' : 'translate3d(0, 0, 0)',
        }}
      >
        <FreeformZoomControls
          zoom={camera.zoom}
          onZoomOut={() =>
            onCameraChange({ ...camera, zoom: clampZoom(camera.zoom * 0.82) }, true)
          }
          onZoomIn={() =>
            onCameraChange({ ...camera, zoom: clampZoom(camera.zoom * 1.22) }, true)
          }
          onResetZoom={() => onCameraChange({ ...camera, zoom: 1.0 }, true)}
          onFitBoard={() =>
            onCameraChange(
              computeFitCamera(document.nodes, viewport.width, viewport.height, 64, 76, 108),
              true,
            )
          }
        />
      </div>

      {/* Bottom-Center Contextual Pill + Floating Tool Dock */}
      <div className="pointer-events-none absolute bottom-4 left-0 right-0 z-20 flex flex-col items-center gap-2 px-4">
        {activeTool === 'pen' && (
          <div
            data-canvas-hud="true"
            onPointerDown={(e) => e.stopPropagation()}
            className="pointer-events-auto"
          >
            <InkPenControlsPill
              colorHex={inkColorHex}
              lineWidth={inkLineWidth}
              opacity={inkOpacity}
              onChangeColor={setInkColorHex}
              onChangeWidth={setInkLineWidth}
              onChangeOpacity={setInkOpacity}
            />
          </div>
        )}

        {activeTool !== 'pen' && selectedConnector && selectedNodes.length === 0 && (
          <div
            data-canvas-hud="true"
            onPointerDown={(e) => e.stopPropagation()}
            className="pointer-events-auto"
          >
            <SelectedConnectorBar
              dashed={selectedConnector.dashed}
              onToggleDashed={() => {
                const cid = selectedConnector.id;
                const nextDashed = !selectedConnector.dashed;
                onCommitDocument((doc) => ({
                  ...doc,
                  connectors: doc.connectors.map((c) =>
                    c.id === cid
                      ? { ...c, dashed: nextDashed, updatedAt: new Date().toISOString() }
                      : c,
                  ),
                }));
              }}
              onDelete={() => {
                const cid = selectedConnector.id;
                setSelectedConnectorID(null);
                onCommitDocument((doc) => ({
                  ...doc,
                  connectors: doc.connectors.filter((c) => c.id !== cid),
                }));
              }}
            />
          </div>
        )}

        {activeTool === 'select' && selectedNodes.length > 0 && (
          <div
            data-canvas-hud="true"
            onPointerDown={(e) => e.stopPropagation()}
            className="pointer-events-auto"
          >
            <SelectedTransformBar
              selectedCount={selectedNodes.length}
              allLocked={selectedNodes.every((n) => n.isLocked)}
              hasCroppedAsset={hasCroppedSelection}
              onRotateCCW={() => rotateSelected(-90)}
              onRotateCW={() => rotateSelected(90)}
              onFlipH={() => flipSelected('h')}
              onFlipV={() => flipSelected('v')}
              onBringForward={() => shiftZIndex('front')}
              onSendBackward={() => shiftZIndex('back')}
              onToggleLock={toggleLockSelected}
              onResetCrop={resetSelectedCrops}
              onDelete={() => deleteNodes(selectedNodeIDs)}
            />
          </div>
        )}

        <div
          data-canvas-hud="true"
          onPointerDown={(e) => e.stopPropagation()}
          className="pointer-events-auto"
        >
          <FloatingToolDock
            activeTool={activeTool}
            connectorStyle={activeConnectorStyle}
            showConnectorStylePicker={activeTool === 'connector' || selectedConnector !== null}
            canUndo={canUndo}
            canRedo={canRedo}
            hasNodes={document.nodes.length > 0}
            onSelectTool={setActiveTool}
            onChangeConnectorStyle={handleChangeConnectorStyle}
            onAddNote={handleAddNote}
            onAddGroupFrame={handleAddGroupFrame}
            onAddPaletteStrip={handleAddPaletteStrip}
            onTidy={onTidyBoard}
            onUndo={onUndo}
            onRedo={onRedo}
            onOpenExport={onOpenExport}
          />
        </div>
      </div>

      {/* External File Drop Ring */}
      {isDropTargeted && (
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-2.5 z-50 rounded-[16px] border-2 border-dashed border-[var(--accent)] bg-[var(--accent-soft)] flex items-center justify-center"
        >
          <span className="px-4 py-2 rounded-full bg-[var(--bg-elevated)] text-[var(--accent)] text-[13px] font-semibold shadow-md border border-[var(--accent-ring)]">
            松开即可导入素材并插入当前画布位置
          </span>
        </div>
      )}
    </div>
  );
};
