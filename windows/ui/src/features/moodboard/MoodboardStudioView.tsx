import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  AlertCircle,
  ArrowLeft,
  ArrowLeftRight,
  ArrowUpRight,
  Box,
  Clipboard,
  Compass,
  Copy,
  Crop,
  Download,
  Eraser,
  ExternalLink,
  Eye,
  FileText,
  Film,
  FlipHorizontal2,
  FlipVertical2,
  FolderOpen,
  Globe,
  Grid2x2,
  Hand,
  Image as ImageIcon,
  Layers,
  LayoutGrid,
  Lock,
  Maximize2,
  Minus,
  MousePointer2,
  Music,
  Palette,
  PanelRight,
  Pencil,
  PenTool,
  Plus,
  Redo2,
  RefreshCw,
  RotateCcw,
  RotateCw,
  Scissors,
  Search,
  Sparkles,
  SquareDashed,
  Star,
  StickyNote,
  Tag,
  Trash2,
  Undo2,
  Unlock,
  Upload,
  Wand2,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  Button,
  CharkleSlider,
  Popover,
  SegmentedControl,
  useResolvedIsDark,
} from '../../design-system';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';
import {
  isAutoEditorialMode,
  msToCocoaSeconds,
  type AssetRecord,
  type BoardImageFormat,
  type BoardNode,
  type BoardPoint,
  type BoardRect,
  type ConnectorAnchor,
  type ConnectorStyle,
  type EditorialStyle,
  type GroupTint,
  type InkStrokePoint,
  type MoodboardExportOptions,
  type NormalizedCropRect,
  type NoteStyle,
  type SidebarDestination,
} from '../../types/domain';
import { useDndStore } from '../dnd/dndStore';
import {
  beginPointerDrag,
  registerPointerDragHandlers,
  wasRecentPointerDrag,
} from '../dnd/PointerDragContext';
import { CANDIDATE_DRAG_MIME, CandidatePoolPanel } from './CandidatePoolPanel';
import {
  GROUP_TINT_PALETTE,
  NOTE_STYLE_PALETTE,
  buildConnectorSvgPath,
  buildInkStrokeSvgPath,
  getGroupTintPalette,
  getNoteStylePalette,
  isLightHex,
  normalizeDegrees,
  reflowNodesInsideGroupFrame,
  sanitizeExportFileName,
  solveEditorialLayout,
} from './editorial';
import { MoodboardGeneratorModal } from './MoodboardGeneratorModal';

type CanvasTool = 'select' | 'hand' | 'connector' | 'ink' | 'eraser';
type ResizeCorner = 'topLeading' | 'topTrailing' | 'bottomLeading' | 'bottomTrailing';

interface CameraState {
  center: BoardPoint;
  zoom: number;
}

interface AlignmentGuides {
  vertical: number | null;
  horizontal: number | null;
}

interface LiveDragState {
  anchorNodeId: string;
  movingIds: Set<string>;
  startClientX: number;
  startClientY: number;
  dx: number;
  dy: number;
  started: boolean;
}

interface LiveResizeState {
  nodeId: string;
  corner: ResizeCorner | null;
  sideEdge: -1 | 0 | 1;
  startClientX: number;
  startClientY: number;
  origRect: BoardRect;
  liveRect: BoardRect;
  rotationDegrees: number;
  kindKey: 'assetRef' | 'note' | 'groupFrame' | 'paletteStrip';
  enclosedChildIds: string[];
  reflowedChildren: Record<string, BoardRect>;
}

interface LiveRotateState {
  nodeId: string;
  centerScreenX: number;
  centerScreenY: number;
  startDegrees: number;
  dragStartAngle: number;
  liveDegrees: number;
}

interface LivePortConnectorState {
  fromNodeID: string;
  fromAnchor: ConnectorAnchor;
  startWorld: BoardPoint;
  cursorWorld: BoardPoint;
}

interface LivePanState {
  startClientX: number;
  startClientY: number;
  startCenter: BoardPoint;
  fromSpace: boolean;
}

interface LiveMarqueeState {
  startScreen: BoardPoint;
  curScreen: BoardPoint;
  started: boolean;
}

interface LiveEraserState {
  strokeIds: Set<string>;
  connectorIds: Set<string>;
}

const SNAP_THRESHOLD_PX = 6;
const CALM_INK_SWATCHES: ReadonlyArray<{ name: string; hex: string }> = [
  { name: '陶红', hex: '#D95D48' },
  { name: '墨炭', hex: '#2C3038' },
  { name: '钴蓝', hex: '#3D6A99' },
  { name: '青苔', hex: '#4D7C5F' },
  { name: '赭黄', hex: '#C7933B' },
  { name: '粉白', hex: '#EFECE6' },
];

const RESIZE_CORNERS: ReadonlyArray<{
  id: ResizeCorner;
  signX: -1 | 1;
  signY: -1 | 1;
  cursor: string;
}> = [
  { id: 'topLeading', signX: -1, signY: -1, cursor: 'nwse-resize' },
  { id: 'topTrailing', signX: 1, signY: -1, cursor: 'nesw-resize' },
  { id: 'bottomLeading', signX: -1, signY: 1, cursor: 'nesw-resize' },
  { id: 'bottomTrailing', signX: 1, signY: 1, cursor: 'nwse-resize' },
];

function isRectInsideGroup(child: BoardRect, group: BoardRect): boolean {
  const cx = child.x + child.width * 0.5;
  const cy = child.y + child.height * 0.5;
  return (
    cx >= group.x &&
    cx <= group.x + group.width &&
    cy >= group.y &&
    cy <= group.y + group.height
  );
}

function positiveMod(a: number, m: number): number {
  const r = a % m;
  return r < 0 ? r + m : r;
}

function minSizeForKindKey(
  kindKey: 'assetRef' | 'note' | 'groupFrame' | 'paletteStrip',
): { width: number; height: number } {
  if (kindKey === 'note') return { width: 140, height: 96 };
  if (kindKey === 'groupFrame') return { width: 180, height: 120 };
  if (kindKey === 'paletteStrip') return { width: 160, height: 48 };
  return { width: 84, height: 60 };
}

function nodeKindKey(kind: BoardNode['kind']): 'assetRef' | 'note' | 'groupFrame' | 'paletteStrip' {
  if ('note' in kind) return 'note';
  if ('groupFrame' in kind) return 'groupFrame';
  if ('paletteStrip' in kind) return 'paletteStrip';
  return 'assetRef';
}

function isPlainWebBookmarkAsset(
  asset: AssetRecord | undefined,
): asset is AssetRecord & { sourceURL: string } {
  return Boolean(
    asset &&
      asset.mediaKind === 'webBookmark' &&
      !asset.richMetadata?.githubRepo &&
      !asset.richMetadata?.socialPost &&
      typeof asset.sourceURL === 'string' &&
      asset.sourceURL.trim().length > 0,
  );
}

export type MoodboardDockLayoutTier = 'wide' | 'medium' | 'compact';

export interface MoodboardDockLayoutSpec {
  tier: MoodboardDockLayoutTier;
  inlineToolOptions: boolean;
  compactButtons: boolean;
  showInsertLabels: boolean;
  showExportLabel: boolean;
  scrollDockFallback: boolean;
  compactHeader: boolean;
  paletteTrailingClearance: boolean;
}

/**
 * Pure 3-tier responsive breakpoint resolver matching macOS `MoodboardDockLayoutTier`.
 * - `wide` (`>= 820`): centered Tool Dock + bottom-right Zoom pill (inline tool options `>= 960`)
 * - `medium` (`560..819`): single-row flex distributing Tool Dock + Zoom pill side-by-side
 * - `compact` (`< 560`): Zoom pill stacks cleanly above-right of Tool Dock (`< 430` horizontal glide)
 */
export function resolveMoodboardDockTier(stageWidth: number): MoodboardDockLayoutTier {
  const w = Number.isFinite(stageWidth) ? stageWidth : 1060;
  if (w >= 820) return 'wide';
  if (w >= 560) return 'medium';
  return 'compact';
}

export function resolveMoodboardDockLayout(stageWidth: number): MoodboardDockLayoutSpec {
  const w = Number.isFinite(stageWidth) ? stageWidth : 1060;
  const tier = resolveMoodboardDockTier(w);
  return {
    tier,
    inlineToolOptions: tier === 'wide' && w >= 960,
    compactButtons: tier === 'compact' || w < 680,
    showInsertLabels: tier === 'wide' || w >= 680,
    showExportLabel: tier === 'wide' || w >= 700,
    scrollDockFallback: w < 430,
    compactHeader: w < 520,
    paletteTrailingClearance: w < 680,
  };
}

function worldToScreen(pt: BoardPoint, cam: CameraState, size: { width: number; height: number }): BoardPoint {
  return {
    x: (pt.x - cam.center.x) * cam.zoom + size.width * 0.5,
    y: (pt.y - cam.center.y) * cam.zoom + size.height * 0.5,
  };
}

function screenToWorld(pt: BoardPoint, cam: CameraState, size: { width: number; height: number }): BoardPoint {
  return {
    x: (pt.x - size.width * 0.5) / cam.zoom + cam.center.x,
    y: (pt.y - size.height * 0.5) / cam.zoom + cam.center.y,
  };
}

function withCacheBust(url: string, updatedAt: number | string | undefined): string {
  if (!url || url.startsWith('data:') || url.startsWith('blob:') || updatedAt === undefined) {
    return url;
  }
  const sep = url.includes('?') ? '&' : '?';
  return `${url}${sep}v=${encodeURIComponent(String(updatedAt))}`;
}

function renderAssetFallbackIcon(kind: AssetRecord['mediaKind'] | undefined) {
  switch (kind) {
    case 'video':
    case 'animatedImage':
      return <Film size={22} strokeWidth={1.5} />;
    case 'audio':
      return <Music size={22} strokeWidth={1.5} />;
    case 'document':
      return <FileText size={22} strokeWidth={1.5} />;
    case 'webBookmark':
      return <Globe size={22} strokeWidth={1.5} />;
    case 'model3D':
      return <Box size={22} strokeWidth={1.5} />;
    default:
      return <ImageIcon size={22} strokeWidth={1.5} />;
  }
}

interface BoardAssetMediaProps {
  assetId: string;
  asset: AssetRecord | undefined;
  libraryBootstrapped: boolean;
  weight: number;
  autoplayLoop: boolean;
  cropStyle: React.CSSProperties;
  onRemoveMissing: () => void;
}

const BoardAssetMedia: React.FC<BoardAssetMediaProps> = ({
  assetId,
  asset,
  libraryBootstrapped,
  weight,
  autoplayLoop,
  cropStyle,
  onRemoveMissing,
}) => {
  const transport = getTransport();
  const isMissing = libraryBootstrapped && !asset;
  const isSwatch = Boolean(asset?.fileName.toLowerCase().endsWith('.swatch'));
  const thumbTier = weight >= 2 ? 'preview1400' : 'grid520';
  const thumbUrl =
    isMissing || isSwatch
      ? ''
      : withCacheBust(transport.thumbnailUrl(assetId, thumbTier), asset?.updatedAt);
  const videoUrl =
    !isMissing && asset?.mediaKind === 'video'
      ? transport.originalUrl(assetId, { cachedOnly: true })
      : '';
  const [imgFailed, setImgFailed] = useState(false);
  const [videoFailed, setVideoFailed] = useState(false);

  useEffect(() => {
    setImgFailed(false);
    setVideoFailed(false);
  }, [assetId, thumbUrl, videoUrl]);

  if (isMissing) {
    return (
      <div
        data-testid="missing-asset-placeholder"
        className="w-full h-full flex flex-col items-center justify-center gap-2 p-3 text-center bg-[var(--bg-subtle)] text-[var(--text-secondary)]"
      >
        <AlertCircle size={20} strokeWidth={1.6} className="text-[var(--text-tertiary)] shrink-0" />
        <div className="text-[11px] font-medium leading-snug text-[var(--text-secondary)]">
          原素材已从素材库移除
        </div>
        <button
          type="button"
          onMouseDown={(e) => e.stopPropagation()}
          onClick={(e) => {
            e.stopPropagation();
            onRemoveMissing();
          }}
          className="charkle-pressable px-2 py-0.5 rounded-[var(--radius-chip)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] hover:border-[var(--danger)] hover:text-[var(--danger)] text-[10.5px] font-medium text-[var(--text-primary)] cursor-pointer"
        >
          从画布移除
        </button>
      </div>
    );
  }

  const primaryHex = asset?.dominantColors?.[0]?.hex?.trim() || null;
  const secondaryHex = asset?.dominantColors?.[1]?.hex?.trim() || null;
  const swatchHex = (primaryHex || '#64748B').toUpperCase();
  const swatchLight = isLightHex(swatchHex);

  if (isSwatch) {
    return (
      <div
        style={{ backgroundColor: swatchHex }}
        className="w-full h-full flex flex-col items-center justify-center gap-1 p-3 select-none"
      >
        <span
          style={{ color: swatchLight ? 'rgba(0,0,0,0.8)' : 'rgba(255,255,255,0.92)' }}
          className="text-[13px] font-semibold charkle-mono tracking-tight"
        >
          {swatchHex}
        </span>
        {asset?.title && (
          <span
            style={{ color: swatchLight ? 'rgba(0,0,0,0.62)' : 'rgba(255,255,255,0.74)' }}
            className="text-[10.5px] font-medium truncate max-w-full"
          >
            {asset.title}
          </span>
        )}
      </div>
    );
  }

  if (asset?.mediaKind === 'video' && !videoFailed && videoUrl) {
    return (
      <video
        src={videoUrl}
        poster={withCacheBust(transport.thumbnailUrl(assetId, 'preview1400'), asset.updatedAt)}
        muted
        loop={autoplayLoop}
        autoPlay={autoplayLoop}
        playsInline
        onError={() => setVideoFailed(true)}
        className="w-full h-full object-cover"
      />
    );
  }

  if (!imgFailed && thumbUrl) {
    return (
      <img
        src={thumbUrl}
        alt={asset?.title ?? '素材'}
        draggable={false}
        onError={() => setImgFailed(true)}
        style={cropStyle}
        className="object-cover"
      />
    );
  }

  const fallbackBackdrop: React.CSSProperties =
    primaryHex && secondaryHex
      ? { backgroundImage: `linear-gradient(135deg, ${primaryHex}33 0%, ${secondaryHex}24 100%)` }
      : primaryHex
        ? { backgroundColor: `${primaryHex}28` }
        : {};

  return (
    <div
      style={fallbackBackdrop}
      className="w-full h-full flex flex-col items-center justify-center gap-1.5 p-3 text-center bg-[var(--bg-subtle)] text-[var(--text-secondary)]"
    >
      {renderAssetFallbackIcon(asset?.mediaKind)}
      <span className="text-[11px] font-medium truncate max-w-full">
        {asset?.title || asset?.fileName || '素材预览不可用'}
      </span>
    </div>
  );
};

export const MoodboardStudioView: React.FC = () => {
  const setDestination = useCoordinatorStore((s) => s.setDestination);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const requestGalleryReveal = useCoordinatorStore((s) => s.requestGalleryReveal);
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const setInspectorOpen = useCoordinatorStore((s) => s.setInspectorOpen);
  const toggleInspector = useCoordinatorStore((s) => s.toggleInspector);
  const setVisualFilterBarOpen = useCoordinatorStore((s) => s.setVisualFilterBarOpen);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const allLibraryAssets = useLibraryStore((s) => s.allAssets);
  const filteredLibraryAssets = useLibraryStore((s) => s.assets);
  const libraryBootstrapped = useLibraryStore((s) => s.bootstrapped);
  const libraryAssets = allLibraryAssets.length > 0 ? allLibraryAssets : filteredLibraryAssets;
  const setCriteria = useLibraryStore((s) => s.setCriteria);
  const clearVisualFilters = useLibraryStore((s) => s.clearVisualFilters);
  const ingestImageBase64 = useLibraryStore((s) => s.ingestImageBase64);

  const pointerDrag = useDndStore((s) => s.pointerDrag);
  const pointerTarget = useDndStore((s) => s.pointerTarget);
  const osFileDrop = useDndStore((s) => s.osFileDrop);

  const activeBoard = useMoodboardStore((s) => s.activeBoard);
  const historyPast = useMoodboardStore((s) => s.historyPast);
  const historyFuture = useMoodboardStore((s) => s.historyFuture);
  const selectedNodeIds = useMoodboardStore((s) => s.selectedNodeIds);
  const swappingNodeId = useMoodboardStore((s) => s.swappingNodeId);
  const clipboardAssetIds = useMoodboardStore((s) => s.clipboardAssetIds);
  const clipboardIsCut = useMoodboardStore((s) => s.clipboardIsCut);
  const setSelectedNodeIds = useMoodboardStore((s) => s.setSelectedNodeIds);
  const setSwappingNodeId = useMoodboardStore((s) => s.setSwappingNodeId);
  const setBoardClipboard = useMoodboardStore((s) => s.setBoardClipboard);
  const mutateActiveBoard = useMoodboardStore((s) => s.mutateActiveBoard);
  const persistViewportQuietly = useMoodboardStore((s) => s.persistViewportQuietly);
  const undo = useMoodboardStore((s) => s.undo);
  const redo = useMoodboardStore((s) => s.redo);
  const addAssetNodeAt = useMoodboardStore((s) => s.addAssetNodeAt);
  const addNoteNode = useMoodboardStore((s) => s.addNoteNode);
  const addGroupFrameNode = useMoodboardStore((s) => s.addGroupFrameNode);
  const addPaletteStripNode = useMoodboardStore((s) => s.addPaletteStripNode);
  const addConnector = useMoodboardStore((s) => s.addConnector);
  const updateConnectorLabel = useMoodboardStore((s) => s.updateConnectorLabel);
  const removeConnector = useMoodboardStore((s) => s.removeConnector);
  const addInkStroke = useMoodboardStore((s) => s.addInkStroke);
  const eraseInkAndConnectors = useMoodboardStore((s) => s.eraseInkAndConnectors);
  const removeNodes = useMoodboardStore((s) => s.removeNodes);
  const switchBoardMode = useMoodboardStore((s) => s.switchBoardMode);
  const tidyActiveBoard = useMoodboardStore((s) => s.tidyActiveBoard);
  const syncBoardPalette = useMoodboardStore((s) => s.syncBoardPalette);

  const isDark = useResolvedIsDark();
  const transport = getTransport();

  const stageRef = useRef<HTMLDivElement | null>(null);
  const exportBtnRef = useRef<HTMLButtonElement | null>(null);
  const cropBtnRef = useRef<HTMLButtonElement | null>(null);

  const [stageSize, setStageSize] = useState({ width: 1060, height: 720 });
  const [tool, setTool] = useState<CanvasTool>('select');
  const [hoveredNodeId, setHoveredNodeId] = useState<string | null>(null);
  const [selectedConnectorId, setSelectedConnectorId] = useState<string | null>(null);
  const [editingNoteId, setEditingNoteId] = useState<string | null>(null);
  const [editingGroupId, setEditingGroupId] = useState<string | null>(null);
  const [editingConnector, setEditingConnector] = useState<{
    id: string;
    x: number;
    y: number;
    draft: string;
  } | null>(null);

  const [genOpen, setGenOpen] = useState(false);
  const [exportOpen, setExportOpen] = useState(false);
  const [cropOpen, setCropOpen] = useState(false);
  const [titleDraft, setTitleDraft] = useState(activeBoard?.title ?? '');
  const [copiedPaletteHex, setCopiedPaletteHex] = useState<string | null>(null);

  // Camera state (center + zoom matching macOS FreeformCameraState)
  const [camera, setCamera] = useState<CameraState>({ center: { x: 520, y: 340 }, zoom: 1 });
  const [cameraAnimated, setCameraAnimated] = useState(false);
  const cameraAnimTimerRef = useRef<number | null>(null);

  // Spacebar tap-for-QuickLook vs hold-and-drag-for-pan
  const [spacePressed, setSpacePressed] = useState(false);
  const spaceHeldRef = useRef(false);
  const didDragDuringSpaceRef = useRef(false);

  // Local 120fps gesture states (ZERO store/IPC mutations mid-drag!)
  const [guides, setGuides] = useState<AlignmentGuides>({ vertical: null, horizontal: null });
  const [liveDrag, setLiveDrag] = useState<LiveDragState | null>(null);
  const [liveResize, setLiveResize] = useState<LiveResizeState | null>(null);
  const [liveRotate, setLiveRotate] = useState<LiveRotateState | null>(null);
  const [livePortConn, setLivePortConn] = useState<LivePortConnectorState | null>(null);
  const [livePan, setLivePan] = useState<LivePanState | null>(null);
  const [liveMarquee, setLiveMarquee] = useState<LiveMarqueeState | null>(null);
  const [liveStroke, setLiveStroke] = useState<InkStrokePoint[] | null>(null);
  const [liveEraser, setLiveEraser] = useState<LiveEraserState | null>(null);

  // Refs synced to latest gesture state so window listeners NEVER tear down/reattach mid-drag
  const liveDragRef = useRef<LiveDragState | null>(null);
  const liveResizeRef = useRef<LiveResizeState | null>(null);
  const liveRotateRef = useRef<LiveRotateState | null>(null);
  const livePortConnRef = useRef<LivePortConnectorState | null>(null);
  const livePanRef = useRef<LivePanState | null>(null);
  const liveMarqueeRef = useRef<LiveMarqueeState | null>(null);
  const liveStrokeRef = useRef<InkStrokePoint[] | null>(null);
  const liveEraserRef = useRef<LiveEraserState | null>(null);
  const lastNodeDragEndedAtRef = useRef<number>(0);

  const [contextMenu, setContextMenu] = useState<
    | {
        kind: 'node';
        nodeId: string;
        targetIds: string[];
        swatchHex?: string | null;
        x: number;
        y: number;
      }
    | { kind: 'canvas'; worldPt: BoardPoint; x: number; y: number }
    | null
  >(null);

  // Click-to-connect state (connector tool mode)
  const [pendingConnector, setPendingConnector] = useState<{
    fromNodeID: string;
    fromNormalizedPoint: BoardPoint;
  } | null>(null);
  const [connectorStyle, setConnectorStyle] = useState<ConnectorStyle>('curved');
  const [connectorDashed, setConnectorDashed] = useState(false);
  const [inkColor, setInkColor] = useState(CALM_INK_SWATCHES[0].hex);
  const [inkWidth, setInkWidth] = useState(3.5);

  // Export popover options
  const [exportScale, setExportScale] = useState<'1' | '2'>('2');
  const [exportFormat, setExportFormat] = useState<BoardImageFormat>('png');
  const [exportAnnotations, setExportAnnotations] = useState(true);
  const [exportPalette, setExportPalette] = useState(true);
  const [exportDark, setExportDark] = useState(isDark);
  const [exporting, setExporting] = useState(false);

  const safeNodes = useMemo(
    () => (Array.isArray(activeBoard?.nodes) ? activeBoard.nodes : []),
    [activeBoard?.nodes],
  );
  const safeConnectors = useMemo(
    () => (Array.isArray(activeBoard?.connectors) ? activeBoard.connectors : []),
    [activeBoard?.connectors],
  );
  const safeInkStrokes = useMemo(
    () => (Array.isArray(activeBoard?.inkStrokes) ? activeBoard.inkStrokes : []),
    [activeBoard?.inkStrokes],
  );
  const safePalette = useMemo(
    () => (Array.isArray(activeBoard?.extractedPalette) ? activeBoard.extractedPalette : []),
    [activeBoard?.extractedPalette],
  );

  const assetsById = useMemo(
    () => new Map<string, AssetRecord>(libraryAssets.map((a) => [a.id, a])),
    [libraryAssets],
  );

  const isEditorial = activeBoard ? isAutoEditorialMode(activeBoard.mode) : false;
  const editorialCfg = useMemo(
    () =>
      activeBoard && isAutoEditorialMode(activeBoard.mode)
        ? activeBoard.mode.autoEditorial._0
        : { columns: 4, spacing: 16, style: 'balanced' as EditorialStyle, showPaletteStrip: true },
    [activeBoard],
  );
  const showTopPaletteStrip = isEditorial ? editorialCfg.showPaletteStrip : true;
  const editorialTopPadding = showTopPaletteStrip && safePalette.length > 0 ? 64 : 28;

  const editorialSolved = useMemo(() => {
    if (!activeBoard || !isEditorial) return null;
    return solveEditorialLayout(
      safeNodes,
      editorialCfg,
      stageSize.width,
      assetsById,
      editorialTopPadding,
    );
  }, [activeBoard, isEditorial, safeNodes, editorialCfg, stageSize.width, assetsById, editorialTopPadding]);

  const baseFrames = useMemo(() => {
    const map = new Map<string, BoardRect>();
    for (const n of safeNodes) {
      map.set(n.id, (isEditorial ? editorialSolved?.frames[n.id] : n.frame) ?? n.frame);
    }
    return map;
  }, [safeNodes, isEditorial, editorialSolved]);

  const effectiveFrame = useCallback(
    (node: BoardNode): BoardRect => {
      if (liveResize && liveResize.nodeId === node.id) {
        return liveResize.liveRect;
      }
      if (liveResize && liveResize.reflowedChildren[node.id]) {
        return liveResize.reflowedChildren[node.id];
      }
      const base = baseFrames.get(node.id) ?? node.frame;
      if (liveDrag && liveDrag.started && liveDrag.movingIds.has(node.id) && !node.isLocked) {
        return {
          x: base.x + liveDrag.dx,
          y: base.y + liveDrag.dy,
          width: base.width,
          height: base.height,
        };
      }
      return base;
    },
    [baseFrames, liveDrag, liveResize],
  );

  const effectiveRotation = useCallback(
    (node: BoardNode): number => {
      if (liveRotate && liveRotate.nodeId === node.id) {
        return liveRotate.liveDegrees;
      }
      return node.rotationDegrees ?? 0;
    },
    [liveRotate],
  );

  const effectiveFramesMap = useMemo(() => {
    const map = new Map<string, BoardRect>();
    for (const n of safeNodes) {
      map.set(n.id, effectiveFrame(n));
    }
    return map;
  }, [safeNodes, effectiveFrame]);

  // Keep latest state in a ref for non-passive wheel & active drag window listeners
  const cameraRef = useRef(camera);
  cameraRef.current = camera;
  const stageSizeRef = useRef(stageSize);
  stageSizeRef.current = stageSize;
  const isEditorialRef = useRef(isEditorial);
  isEditorialRef.current = isEditorial;
  const safeNodesRef = useRef(safeNodes);
  safeNodesRef.current = safeNodes;
  const safeConnectorsRef = useRef(safeConnectors);
  safeConnectorsRef.current = safeConnectors;
  const safeInkStrokesRef = useRef(safeInkStrokes);
  safeInkStrokesRef.current = safeInkStrokes;
  const assetsByIdRef = useRef(assetsById);
  assetsByIdRef.current = assetsById;
  const effectiveFramesRef = useRef(effectiveFramesMap);
  effectiveFramesRef.current = effectiveFramesMap;
  const connectorStyleRef = useRef(connectorStyle);
  connectorStyleRef.current = connectorStyle;
  const connectorDashedRef = useRef(connectorDashed);
  connectorDashedRef.current = connectorDashed;
  const inkColorRef = useRef(inkColor);
  inkColorRef.current = inkColor;
  const inkWidthRef = useRef(inkWidth);
  inkWidthRef.current = inkWidth;

  const isAnyGestureActive = Boolean(
    liveDrag ||
      liveResize ||
      liveRotate ||
      livePortConn ||
      livePan ||
      liveMarquee ||
      liveStroke ||
      liveEraser,
  );

  const triggerSmoothCameraUpdate = useCallback(
    (updater: (prev: CameraState) => CameraState, persist = true) => {
      const reduced =
        typeof window !== 'undefined' &&
        window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
      if (!reduced) {
        setCameraAnimated(true);
        if (cameraAnimTimerRef.current !== null) {
          window.clearTimeout(cameraAnimTimerRef.current);
        }
        cameraAnimTimerRef.current = window.setTimeout(() => {
          setCameraAnimated(false);
          cameraAnimTimerRef.current = null;
        }, 240);
      }
      setCamera((prev) => {
        const next = updater(prev);
        cameraRef.current = next;
        if (persist) persistViewportQuietly(next.center, next.zoom);
        return next;
      });
    },
    [persistViewportQuietly],
  );

  // Sync camera whenever switching to a different board
  useEffect(() => {
    setTitleDraft(activeBoard?.title ?? '');
  }, [activeBoard?.id, activeBoard?.title]);

  useEffect(() => {
    if (!activeBoard) return;
    const nodes = Array.isArray(activeBoard.nodes) ? activeBoard.nodes : [];
    const initialZoom = Math.max(0.2, Math.min(3.0, activeBoard.viewportZoom > 0 ? activeBoard.viewportZoom : 1));
    let initialCenter = activeBoard.viewportCenter ?? { x: 520, y: 340 };
    if (initialCenter.x === 0 && initialCenter.y === 0 && nodes.length > 0) {
      const minX = Math.min(...nodes.map((n) => n.frame.x));
      const maxX = Math.max(...nodes.map((n) => n.frame.x + n.frame.width));
      const minY = Math.min(...nodes.map((n) => n.frame.y));
      const maxY = Math.max(...nodes.map((n) => n.frame.y + n.frame.height));
      initialCenter = { x: (minX + maxX) * 0.5, y: Math.min((minY + maxY) * 0.5, 420) };
    }
    const next = { center: initialCenter, zoom: initialZoom };
    setCameraAnimated(false);
    setCamera(next);
    cameraRef.current = next;
    liveDragRef.current = null;
    liveResizeRef.current = null;
    liveRotateRef.current = null;
    livePortConnRef.current = null;
    livePanRef.current = null;
    liveMarqueeRef.current = null;
    liveStrokeRef.current = null;
    liveEraserRef.current = null;
    setLiveDrag(null);
    setLiveResize(null);
    setLiveRotate(null);
    setLivePortConn(null);
    setLivePan(null);
    setLiveMarquee(null);
    setLiveStroke(null);
    setLiveEraser(null);
    setGuides({ vertical: null, horizontal: null });
    setContextMenu(null);
    setCropOpen(false);
    setSelectedConnectorId(null);
    setEditingConnector(null);
    setEditingNoteId(null);
    setEditingGroupId(null);
    setPendingConnector(null);
    setTool('select');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeBoard?.id]);

  // Reset Freeform-only tools (hand/ink/eraser) when entering Auto Editorial so cards stay interactive
  useEffect(() => {
    if (!isEditorial) return;
    setTool((prev) => (prev === 'hand' || prev === 'ink' || prev === 'eraser' ? 'select' : prev));
    setPendingConnector(null);
  }, [isEditorial]);

  // Sync dark export default when appearance changes
  useEffect(() => {
    setExportDark(isDark);
  }, [isDark]);

  // Clean up timers, active gesture refs, and flush pending debounced saves on unmount
  useEffect(() => {
    return () => {
      if (cameraAnimTimerRef.current !== null) {
        window.clearTimeout(cameraAnimTimerRef.current);
      }
      liveDragRef.current = null;
      liveResizeRef.current = null;
      liveRotateRef.current = null;
      livePortConnRef.current = null;
      livePanRef.current = null;
      liveMarqueeRef.current = null;
      liveStrokeRef.current = null;
      liveEraserRef.current = null;
      void useMoodboardStore.getState().flushPendingSaves();
    };
  }, []);

  // Measure canvas stage viewport via ResizeObserver
  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const measure = () => {
      const w = Math.floor(el.clientWidth);
      const h = Math.floor(el.clientHeight);
      if (w > 40 && h > 40) {
        setStageSize((prev) =>
          Math.abs(prev.width - w) >= 1 || Math.abs(prev.height - h) >= 1
            ? { width: w, height: h }
            : prev,
        );
      }
    };
    measure();
    if (typeof ResizeObserver === 'undefined') return;
    const obs = new ResizeObserver(measure);
    obs.observe(el);
    return () => obs.disconnect();
  }, [activeBoard?.id]);

  const clientToStage = useCallback((clientX: number, clientY: number): BoardPoint => {
    const el = stageRef.current;
    if (!el) return { x: clientX, y: clientY };
    const rect = el.getBoundingClientRect();
    return { x: clientX - rect.left, y: clientY - rect.top };
  }, []);

  const clientToWorld = useCallback(
    (clientX: number, clientY: number): BoardPoint => {
      const el = stageRef.current;
      if (!el) return { x: 0, y: 0 };
      const rect = el.getBoundingClientRect();
      if (isEditorialRef.current) {
        return {
          x: clientX - rect.left + el.scrollLeft,
          y: clientY - rect.top + el.scrollTop,
        };
      }
      return screenToWorld(
        { x: clientX - rect.left, y: clientY - rect.top },
        cameraRef.current,
        stageSizeRef.current,
      );
    },
    [],
  );

  const applyZoomAtScreenPoint = useCallback(
    (factor: number, sx: number, sy: number, animate = false) => {
      const update = (prev: CameraState): CameraState => {
        const size = stageSizeRef.current;
        const worldBefore = screenToWorld({ x: sx, y: sy }, prev, size);
        const nextZoom = Math.max(0.2, Math.min(3.0, prev.zoom * factor));
        const nextCam: CameraState = { center: prev.center, zoom: nextZoom };
        const worldAfter = screenToWorld({ x: sx, y: sy }, nextCam, size);
        return {
          zoom: nextZoom,
          center: {
            x: prev.center.x + (worldBefore.x - worldAfter.x),
            y: prev.center.y + (worldBefore.y - worldAfter.y),
          },
        };
      };
      if (animate) {
        triggerSmoothCameraUpdate(update, true);
      } else {
        setCameraAnimated(false);
        setCamera((prev) => {
          const next = update(prev);
          cameraRef.current = next;
          persistViewportQuietly(next.center, next.zoom);
          return next;
        });
      }
    },
    [persistViewportQuietly, triggerSmoothCameraUpdate],
  );

  const fitBoardToScreen = useCallback(() => {
    const nodes = safeNodesRef.current;
    const size = stageSizeRef.current;
    if (nodes.length === 0) {
      triggerSmoothCameraUpdate(() => ({
        center: { x: size.width * 0.5, y: size.height * 0.5 },
        zoom: 1,
      }));
      return;
    }
    const minX = Math.min(...nodes.map((n) => n.frame.x));
    const minY = Math.min(...nodes.map((n) => n.frame.y));
    const maxX = Math.max(...nodes.map((n) => n.frame.x + n.frame.width));
    const maxY = Math.max(...nodes.map((n) => n.frame.y + n.frame.height));
    const w = Math.max(200, maxX - minX);
    const h = Math.max(200, maxY - minY);
    const fitZoom = Math.min((size.width - 120) / w, (size.height - 160) / h);
    triggerSmoothCameraUpdate(() => ({
      center: { x: (minX + maxX) * 0.5, y: (minY + maxY) * 0.5 },
      zoom: Math.max(0.22, Math.min(1.8, fitZoom)),
    }));
  }, [triggerSmoothCameraUpdate]);

  // Non-passive native wheel listener on stageRef (zoom-around-cursor + smooth pan)
  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      if (isEditorialRef.current) return;
      e.preventDefault();
      const rect = el.getBoundingClientRect();
      const sx = e.clientX - rect.left;
      const sy = e.clientY - rect.top;

      if (e.ctrlKey || e.metaKey || e.altKey) {
        const clamped = Math.max(-120, Math.min(120, e.deltaY));
        const factor = Math.exp(-clamped * 0.0045);
        applyZoomAtScreenPoint(factor, sx, sy, false);
        return;
      }

      const dx = e.shiftKey && Math.abs(e.deltaX) < 0.5 ? e.deltaY : e.deltaX;
      const dy = e.shiftKey && Math.abs(e.deltaX) < 0.5 ? 0 : e.deltaY;
      if (dx === 0 && dy === 0) return;

      setCameraAnimated(false);
      setCamera((prev) => {
        const next: CameraState = {
          zoom: prev.zoom,
          center: {
            x: prev.center.x + dx / prev.zoom,
            y: prev.center.y + dy / prev.zoom,
          },
        };
        cameraRef.current = next;
        persistViewportQuietly(next.center, next.zoom);
        return next;
      });
    };

    el.addEventListener('wheel', onWheel, { passive: false });
    return () => el.removeEventListener('wheel', onWheel);
  }, [activeBoard?.id, applyZoomAtScreenPoint, persistViewportQuietly]);

  // Selection & Transform helpers matching macOS MoodboardCanvasView
  const selectedUnlockedNodes = useMemo(
    () => safeNodes.filter((n) => selectedNodeIds.includes(n.id) && !n.isLocked),
    [safeNodes, selectedNodeIds],
  );

  const selectedSingleNode = useMemo<BoardNode | null>(() => {
    if (selectedNodeIds.length !== 1) return null;
    return safeNodes.find((n) => n.id === selectedNodeIds[0]) ?? null;
  }, [safeNodes, selectedNodeIds]);

  useEffect(() => {
    setCropOpen(false);
  }, [selectedSingleNode?.id]);

  const rotateNodes = useCallback(
    (ids: string[], delta: number) => {
      if (ids.length === 0) return;
      const idSet = new Set(ids);
      mutateActiveBoard((doc) => ({
        ...doc,
        nodes: doc.nodes.map((n) =>
          idSet.has(n.id) && !n.isLocked
            ? { ...n, rotationDegrees: normalizeDegrees(n.rotationDegrees + delta) }
            : n,
        ),
      }));
    },
    [mutateActiveBoard],
  );

  const resetNodesRotation = useCallback(
    (ids: string[]) => {
      if (ids.length === 0) return;
      const idSet = new Set(ids);
      mutateActiveBoard((doc) => ({
        ...doc,
        nodes: doc.nodes.map((n) =>
          idSet.has(n.id) && !n.isLocked ? { ...n, rotationDegrees: 0 } : n,
        ),
      }));
    },
    [mutateActiveBoard],
  );

  const flipNodes = useCallback(
    (ids: string[], horizontal: boolean) => {
      if (ids.length === 0) return;
      const idSet = new Set(ids);
      mutateActiveBoard((doc) => ({
        ...doc,
        nodes: doc.nodes.map((n) =>
          idSet.has(n.id) && !n.isLocked
            ? horizontal
              ? { ...n, flipHorizontal: !n.flipHorizontal }
              : { ...n, flipVertical: !n.flipVertical }
            : n,
        ),
      }));
    },
    [mutateActiveBoard],
  );

  const enclosedChildIdsFor = useCallback(
    (groupNode: BoardNode): string[] =>
      safeNodesRef.current
        .filter(
          (other) =>
            other.id !== groupNode.id &&
            !other.isLocked &&
            !('groupFrame' in other.kind) &&
            isRectInsideGroup(other.frame, groupNode.frame),
        )
        .map((o) => o.id),
    [],
  );

  const reflowGroupFrameNow = useCallback(
    (groupNodeId: string) => {
      const group = safeNodesRef.current.find((n) => n.id === groupNodeId);
      if (!group) return;
      const childIds = enclosedChildIdsFor(group);
      if (childIds.length === 0) return;
      const idSet = new Set(childIds);
      const children = safeNodesRef.current.filter((n) => idSet.has(n.id));
      const reflowed = reflowNodesInsideGroupFrame(group.frame, children, assetsByIdRef.current);
      mutateActiveBoard((doc) => ({
        ...doc,
        nodes: doc.nodes.map((n) => (reflowed[n.id] ? { ...n, frame: reflowed[n.id] } : n)),
      }));
    },
    [enclosedChildIdsFor, mutateActiveBoard],
  );

  const getSpawnWorldCenter = useCallback((): BoardPoint => {
    if (!isEditorialRef.current) return { ...cameraRef.current.center };
    return { x: 260, y: 200 };
  }, []);

  const handleCopyAssets = useCallback(
    async (assetIds: string[]) => {
      if (assetIds.length === 0) return;
      setBoardClipboard(assetIds, false);
      try {
        await transport.copyAssetsToClipboard(assetIds);
        pushToast({ message: `已拷贝 ${assetIds.length} 项素材到剪贴板`, tone: 'success' });
      } catch {
        pushToast({ message: `已拷贝 ${assetIds.length} 项到情绪板剪贴板`, tone: 'info' });
      }
    },
    [pushToast, setBoardClipboard, transport],
  );

  const removeBoardNodesWithFeedback = useCallback(
    (nodeIds: string[]) => {
      if (nodeIds.length === 0) return;
      setEditingNoteId((cur) => (cur && nodeIds.includes(cur) ? null : cur));
      setEditingGroupId((cur) => (cur && nodeIds.includes(cur) ? null : cur));
      removeNodes(nodeIds, { assetsById: assetsByIdRef.current, showUndoToast: true });
    },
    [removeNodes],
  );

  const handleCutNodes = useCallback(
    async (nodeIds: string[]) => {
      if (nodeIds.length === 0) return;
      const idSet = new Set(nodeIds);
      const assetIds = Array.from(
        new Set(
          safeNodesRef.current
            .filter((n) => idSet.has(n.id) && 'assetRef' in n.kind)
            .map((n) => ('assetRef' in n.kind ? n.kind.assetRef.assetID : ''))
            .filter(Boolean),
        ),
      );
      if (assetIds.length > 0) {
        setBoardClipboard(assetIds, true);
        void transport.copyAssetsToClipboard(assetIds).catch(() => {});
      }
      const existingIds = safeNodesRef.current
        .filter((n) => idSet.has(n.id))
        .map((n) => n.id);
      if (existingIds.length > 0) {
        setEditingNoteId((cur) => (cur && existingIds.includes(cur) ? null : cur));
        setEditingGroupId((cur) => (cur && existingIds.includes(cur) ? null : cur));
        removeNodes(existingIds, { assetsById: assetsByIdRef.current, showUndoToast: false });
        const cutMsg =
          assetIds.length > 0
            ? assetIds.length === existingIds.length
              ? `已剪切 ${assetIds.length} 项素材，可按 Ctrl+V 粘贴`
              : `已剪切 ${assetIds.length} 项素材（共移除 ${existingIds.length} 项），可按 Ctrl+V 粘贴`
            : `已移除 ${existingIds.length} 项画布元素`;
        pushToast({
          message: cutMsg,
          tone: 'info',
          actionLabel: '撤销',
          durationMs: 4200,
          onAction: () => useMoodboardStore.getState().undo(),
        });
      }
    },
    [pushToast, removeNodes, setBoardClipboard, transport],
  );

  const handlePasteIntoBoard = useCallback(
    (dropPt?: BoardPoint) => {
      const origin = dropPt ?? getSpawnWorldCenter();
      if (clipboardAssetIds.length > 0) {
        clipboardAssetIds.forEach((aid, idx) => {
          addAssetNodeAt(
            aid,
            { x: origin.x + idx * 24, y: origin.y + idx * 24 },
            assetsByIdRef.current.get(aid) ?? null,
          );
        });
        if (clipboardIsCut) {
          setBoardClipboard([], false);
        }
        syncBoardPalette(assetsByIdRef.current);
        pushToast({
          message: `已粘贴 ${clipboardAssetIds.length} 项素材到情绪板`,
          tone: 'success',
        });
        return;
      }
      pushToast({ message: '剪贴板中没有可粘贴的情绪板素材', tone: 'info', durationMs: 2200 });
    },
    [
      addAssetNodeAt,
      clipboardAssetIds,
      clipboardIsCut,
      getSpawnWorldCenter,
      pushToast,
      setBoardClipboard,
      syncBoardPalette,
    ],
  );

  const openBoardAsset = useCallback(
    (
      assetId: string,
      anchorRect: { left: number; top: number; width: number; height: number } | null,
    ) => {
      const asset = assetsByIdRef.current.get(assetId);
      if (!asset && useLibraryStore.getState().bootstrapped) {
        pushToast({ message: '原素材已从素材库移除，无法预览', tone: 'info', durationMs: 2400 });
        return;
      }
      if (isPlainWebBookmarkAsset(asset)) {
        const url = asset.sourceURL.trim();
        let domain = asset.sourceDomain?.trim() || '';
        if (!domain) {
          try {
            domain = new URL(url).hostname.replace(/^www\./i, '');
          } catch {
            domain = url;
          }
        }
        void transport
          .openExternalUrl(url)
          .then(() => {
            pushToast({
              message: `已在默认浏览器中打开 ${domain}`,
              tone: 'info',
              durationMs: 2200,
            });
          })
          .catch((err) => {
            pushToast({
              message: `打开网页失败：${err instanceof Error ? err.message : String(err)}`,
              tone: 'error',
            });
          });
        void transport.markAssetOpened(asset.id).catch(() => {});
        return;
      }
      (document.activeElement as HTMLElement | null)?.blur?.();
      openQuickLook(assetId, anchorRect);
    },
    [openQuickLook, pushToast, transport],
  );

  const openQuickLookForSelectedNode = useCallback((): boolean => {
    const first = safeNodesRef.current.find(
      (n) => selectedNodeIds.includes(n.id) && 'assetRef' in n.kind,
    );
    if (!first || !('assetRef' in first.kind)) return false;
    const nodeEl = document.querySelector(`[data-board-node-id="${first.id}"]`) as HTMLElement | null;
    const rect = nodeEl?.getBoundingClientRect();
    openBoardAsset(
      first.kind.assetRef.assetID,
      rect ? { left: rect.left, top: rect.top, width: rect.width, height: rect.height } : null,
    );
    return true;
  }, [openBoardAsset, selectedNodeIds]);

  // Complete macOS keyboard shortcut parity (V/H/C/P/E, R/Shift+R, Shift+H/V, Ctrl+A/C/X/V,
  // Space tap Quick Look vs Space+drag pan, Delete/Backspace, Escape, Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y)
  useEffect(() => {
    const isOverlaySuspended = () => {
      const coord = useCoordinatorStore.getState();
      return Boolean(
        coord.quickLookAssetId ||
          coord.settingsOpen ||
          coord.jumpOpen ||
          coord.captureOpen ||
          coord.onboardingOpen ||
          coord.moodboardGeneratorOpen ||
          genOpen,
      );
    };

    const resetSpace = () => {
      spaceHeldRef.current = false;
      didDragDuringSpaceRef.current = false;
      setSpacePressed(false);
    };

    const onKeyDown = (e: KeyboardEvent) => {
      if (isOverlaySuspended() || Boolean(document.querySelector('[role="dialog"][aria-modal="true"]'))) {
        resetSpace();
        return;
      }
      if (e.defaultPrevented || e.isComposing || e.keyCode === 229) return;
      const target = e.target as HTMLElement | null;
      const typing =
        target?.tagName === 'INPUT' ||
        target?.tagName === 'TEXTAREA' ||
        target?.tagName === 'SELECT' ||
        target?.isContentEditable;
      if (typing) return;

      const mod = e.ctrlKey || e.metaKey;
      const lower = e.key.toLowerCase();
      const noMod = !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey;

      if (mod && lower === 'z' && !e.shiftKey) {
        e.preventDefault();
        undo();
        return;
      }
      if ((mod && lower === 'y') || (mod && e.shiftKey && lower === 'z')) {
        e.preventDefault();
        redo();
        return;
      }

      if (mod && !e.shiftKey && !e.altKey) {
        if (lower === 'a') {
          e.preventDefault();
          setSelectedNodeIds(safeNodesRef.current.map((n) => n.id));
          setSelectedConnectorId(null);
          return;
        }
        if (lower === 'c') {
          const assetIds = Array.from(
            new Set(
              safeNodesRef.current
                .filter((n) => selectedNodeIds.includes(n.id) && 'assetRef' in n.kind)
                .map((n) => ('assetRef' in n.kind ? n.kind.assetRef.assetID : ''))
                .filter(Boolean),
            ),
          );
          if (assetIds.length > 0) {
            e.preventDefault();
            void handleCopyAssets(assetIds);
          }
          return;
        }
        if (lower === 'x') {
          if (selectedNodeIds.length > 0) {
            e.preventDefault();
            void handleCutNodes(selectedNodeIds);
          }
          return;
        }
        if (lower === 'v') {
          if (clipboardAssetIds.length > 0) {
            e.preventDefault();
            handlePasteIntoBoard();
          }
          return;
        }
      }

      if (e.key === 'Delete' || e.key === 'Backspace') {
        if (selectedNodeIds.length > 0 || selectedConnectorId) {
          e.preventDefault();
          if (selectedNodeIds.length > 0) {
            removeBoardNodesWithFeedback(selectedNodeIds);
          }
          if (selectedConnectorId) {
            removeConnector(selectedConnectorId);
            setSelectedConnectorId(null);
          }
        }
        return;
      }

      if (e.key === 'Enter' && noMod && selectedNodeIds.length === 1) {
        const onlyNode = safeNodesRef.current.find((n) => n.id === selectedNodeIds[0]);
        if (onlyNode && !onlyNode.isLocked && 'note' in onlyNode.kind) {
          e.preventDefault();
          setEditingGroupId(null);
          setEditingNoteId(onlyNode.id);
          return;
        }
      }

      if (e.key === 'Escape') {
        if (pendingConnector) {
          setPendingConnector(null);
          return;
        }
        if (contextMenu || editingConnector) {
          setContextMenu(null);
          setEditingConnector(null);
          return;
        }
        if (tool !== 'select') {
          setTool('select');
          return;
        }
        setSelectedNodeIds([]);
        setSelectedConnectorId(null);
        setSwappingNodeId(null);
        return;
      }

      // Spacebar: hold + drag pans; quick tap opens Quick Look
      if (e.code === 'Space' && noMod) {
        e.preventDefault();
        if (!e.repeat && !spaceHeldRef.current) {
          spaceHeldRef.current = true;
          didDragDuringSpaceRef.current = false;
          setSpacePressed(true);
        }
        return;
      }

      // Transform shortcuts when unlocked nodes are selected
      const unlockedIds = safeNodesRef.current
        .filter((n) => selectedNodeIds.includes(n.id) && !n.isLocked)
        .map((n) => n.id);
      if (unlockedIds.length > 0) {
        if (lower === 'r' && noMod) {
          e.preventDefault();
          rotateNodes(unlockedIds, 90);
          return;
        }
        if (lower === 'r' && e.shiftKey && !mod && !e.altKey) {
          e.preventDefault();
          rotateNodes(unlockedIds, -90);
          return;
        }
        if (lower === 'h' && e.shiftKey && !mod && !e.altKey) {
          e.preventDefault();
          flipNodes(unlockedIds, true);
          return;
        }
        if (lower === 'v' && e.shiftKey && !mod && !e.altKey) {
          e.preventDefault();
          flipNodes(unlockedIds, false);
          return;
        }
      }

      if (noMod) {
        if (lower === 'v') {
          setTool('select');
        } else if (lower === 'h') {
          if (isEditorialRef.current) {
            switchBoardMode('freeform', stageSizeRef.current.width, assetsByIdRef.current);
          }
          setTool('hand');
        } else if (lower === 'c') {
          setTool('connector');
        } else if (lower === 'p') {
          if (isEditorialRef.current) {
            switchBoardMode('freeform', stageSizeRef.current.width, assetsByIdRef.current);
          }
          setTool('ink');
        } else if (lower === 'e') {
          if (isEditorialRef.current) {
            switchBoardMode('freeform', stageSizeRef.current.width, assetsByIdRef.current);
          }
          setTool('eraser');
        }
      }
    };

    const onKeyUp = (e: KeyboardEvent) => {
      if (e.code === 'Space' && spaceHeldRef.current) {
        const shouldQuickTap = !didDragDuringSpaceRef.current;
        resetSpace();
        if (shouldQuickTap && !isOverlaySuspended()) {
          openQuickLookForSelectedNode();
        }
      }
    };

    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keyup', onKeyUp);
    window.addEventListener('blur', resetSpace);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keyup', onKeyUp);
      window.removeEventListener('blur', resetSpace);
    };
  }, [
    undo,
    redo,
    removeBoardNodesWithFeedback,
    removeConnector,
    selectedNodeIds,
    selectedConnectorId,
    pendingConnector,
    contextMenu,
    editingConnector,
    tool,
    genOpen,
    clipboardAssetIds,
    setSelectedNodeIds,
    setSwappingNodeId,
    rotateNodes,
    flipNodes,
    switchBoardMode,
    handleCopyAssets,
    handleCutNodes,
    handlePasteIntoBoard,
    openQuickLookForSelectedNode,
  ]);

  // Reorder helper for Auto Editorial drag-to-reorder
  const reorderEditorialNode = useCallback(
    (fromId: string, toId: string) => {
      if (fromId === toId) return;
      mutateActiveBoard((doc) => {
        const sorted = [...doc.nodes].sort((a, b) => a.editorialOrder - b.editorialOrder);
        const fromIdx = sorted.findIndex((n) => n.id === fromId);
        const toIdx = sorted.findIndex((n) => n.id === toId);
        if (fromIdx < 0 || toIdx < 0) return doc;
        const [moved] = sorted.splice(fromIdx, 1);
        sorted.splice(toIdx, 0, moved);
        const orderMap = new Map(sorted.map((n, idx) => [n.id, idx]));
        return {
          ...doc,
          nodes: doc.nodes.map((n) => ({
            ...n,
            editorialOrder: orderMap.get(n.id) ?? n.editorialOrder,
          })),
        };
      });
    },
    [mutateActiveBoard],
  );

  // Register PointerDrag handlers for Candidate -> Canvas & Auto-Editorial reorder
  useEffect(() => {
    return registerPointerDragHandlers({
      onDropCandidateToCanvas: (assetId, clientX, clientY) => {
        const pt = clientToWorld(clientX, clientY);
        addAssetNodeAt(assetId, pt, assetsByIdRef.current.get(assetId) ?? null);
      },
      onReorderEditorialNode: (sourceNodeId, targetNodeId) => {
        reorderEditorialNode(sourceNodeId, targetNodeId);
      },
    });
  }, [addAssetNodeAt, clientToWorld, reorderEditorialNode]);

  // Listen for native Tauri v2 OS file drops routed onto the canvas stage
  useEffect(() => {
    const onCanvasFileDrop = (ev: Event) => {
      const detail = (
        ev as CustomEvent<{ assetIds: string[]; clientX: number; clientY: number }>
      ).detail;
      if (!detail?.assetIds?.length) return;
      const basePt = clientToWorld(detail.clientX, detail.clientY);
      detail.assetIds.forEach((assetId, idx) => {
        addAssetNodeAt(
          assetId,
          { x: basePt.x + idx * 28, y: basePt.y + idx * 24 },
          assetsByIdRef.current.get(assetId) ?? null,
        );
      });
    };
    window.addEventListener('charkle:canvas-file-drop', onCanvasFileDrop);
    return () => window.removeEventListener('charkle:canvas-file-drop', onCanvasFileDrop);
  }, [addAssetNodeAt, clientToWorld]);

  const sweepEraseAtWorldPoint = useCallback((worldPt: BoardPoint) => {
    const eraser = liveEraserRef.current;
    if (!eraser) return;
    const hitRadius = 18 / Math.max(0.2, cameraRef.current.zoom);
    let changed = false;

    for (const stroke of safeInkStrokesRef.current) {
      if (eraser.strokeIds.has(stroke.id)) continue;
      if (stroke.points.some((pt) => Math.hypot(pt.x - worldPt.x, pt.y - worldPt.y) <= hitRadius)) {
        eraser.strokeIds.add(stroke.id);
        changed = true;
      }
    }

    const frames = effectiveFramesRef.current;
    for (const conn of safeConnectorsRef.current) {
      if (eraser.connectorIds.has(conn.id)) continue;
      const fr = frames.get(conn.fromNodeID);
      const tr = frames.get(conn.toNodeID);
      if (!fr || !tr) continue;
      const geom = buildConnectorSvgPath(conn, fr, tr);
      const distMid = Math.hypot(geom.mid.x - worldPt.x, geom.mid.y - worldPt.y);
      const distStart = Math.hypot(geom.start.x - worldPt.x, geom.start.y - worldPt.y);
      const distEnd = Math.hypot(geom.end.x - worldPt.x, geom.end.y - worldPt.y);
      if (Math.min(distMid, distStart, distEnd) <= hitRadius * 1.45) {
        eraser.connectorIds.add(conn.id);
        changed = true;
      }
    }

    if (changed) {
      setLiveEraser({
        strokeIds: new Set(eraser.strokeIds),
        connectorIds: new Set(eraser.connectorIds),
      });
    }
  }, []);

  // Single unified gesture listener attached ONCE for the lifetime of an active gesture!
  // Zero store mutations during move, zero listener teardown/reattach thrash!
  useEffect(() => {
    if (!isAnyGestureActive) return;

    const handleMove = (clientX: number, clientY: number, shiftKey: boolean) => {
      // 1. Camera pan
      const pan = livePanRef.current;
      if (pan) {
        const dx = clientX - pan.startClientX;
        const dy = clientY - pan.startClientY;
        if (pan.fromSpace && Math.hypot(dx, dy) >= 2) {
          didDragDuringSpaceRef.current = true;
        }
        const z = cameraRef.current.zoom;
        const next: CameraState = {
          zoom: z,
          center: {
            x: pan.startCenter.x - dx / z,
            y: pan.startCenter.y - dy / z,
          },
        };
        cameraRef.current = next;
        setCamera(next);
        return;
      }

      // 2. Ink Pen stroke
      const stroke = liveStrokeRef.current;
      if (stroke) {
        const pt = clientToWorld(clientX, clientY);
        const last = stroke[stroke.length - 1];
        const minDist = 2 / Math.max(0.2, cameraRef.current.zoom);
        if (!last || Math.hypot(pt.x - last.x, pt.y - last.y) >= minDist) {
          const next = [...stroke, { x: pt.x, y: pt.y, pressure: 0.6 }];
          liveStrokeRef.current = next;
          setLiveStroke(next);
        }
        return;
      }

      // 3. Eraser sweep
      if (liveEraserRef.current) {
        sweepEraseAtWorldPoint(clientToWorld(clientX, clientY));
        return;
      }

      // 4. Connector edge-port drag
      const portConn = livePortConnRef.current;
      if (portConn) {
        const cursorWorld = clientToWorld(clientX, clientY);
        const next = { ...portConn, cursorWorld };
        livePortConnRef.current = next;
        setLivePortConn(next);
        return;
      }

      // 5. Marquee rubber-band selection
      const mq = liveMarqueeRef.current;
      if (mq) {
        const screenPt = clientToStage(clientX, clientY);
        const dist = Math.hypot(screenPt.x - mq.startScreen.x, screenPt.y - mq.startScreen.y);
        const started = mq.started || dist >= 4;
        const next: LiveMarqueeState = { ...mq, curScreen: screenPt, started };
        liveMarqueeRef.current = next;
        setLiveMarquee(next);
        if (started) {
          const w1 = screenToWorld(mq.startScreen, cameraRef.current, stageSizeRef.current);
          const w2 = screenToWorld(screenPt, cameraRef.current, stageSizeRef.current);
          const left = Math.min(w1.x, w2.x);
          const right = Math.max(w1.x, w2.x);
          const top = Math.min(w1.y, w2.y);
          const bottom = Math.max(w1.y, w2.y);
          const hit = safeNodesRef.current
            .filter((n) => {
              const r = n.frame;
              return r.x < right && r.x + r.width > left && r.y < bottom && r.y + r.height > top;
            })
            .map((n) => n.id);
          setSelectedNodeIds(hit);
        }
        return;
      }

      // 6. Rotation knob drag
      const rot = liveRotateRef.current;
      if (rot) {
        const angleNow =
          (Math.atan2(clientY - rot.centerScreenY, clientX - rot.centerScreenX) * 180) / Math.PI;
        let raw = normalizeDegrees(rot.startDegrees + (angleNow - rot.dragStartAngle));
        if (shiftKey) {
          raw = normalizeDegrees(Math.round(raw / 15) * 15);
        } else {
          for (const target of [0, 90, -90, 180, -180]) {
            if (Math.abs(raw - target) <= 3) {
              raw = target === -180 ? 180 : target;
              break;
            }
          }
        }
        const next = { ...rot, liveDegrees: raw };
        liveRotateRef.current = next;
        setLiveRotate(next);
        return;
      }

      // 7. Resize drag (4 corners + GroupFrame left/right side edges)
      const res = liveResizeRef.current;
      if (res) {
        const z = cameraRef.current.zoom;
        const stageDX = (clientX - res.startClientX) / z;
        const stageDY = (clientY - res.startClientY) / z;
        const start = res.origRect;
        const minS = minSizeForKindKey(res.kindKey);

        let updatedRect: BoardRect;
        if (res.sideEdge !== 0) {
          const newW = Math.max(minS.width, start.width + res.sideEdge * stageDX);
          const newX = res.sideEdge < 0 ? start.x + start.width - newW : start.x;
          updatedRect = { x: newX, y: start.y, width: newW, height: start.height };
        } else {
          const cornerMeta =
            RESIZE_CORNERS.find((c) => c.id === res.corner) ?? RESIZE_CORNERS[3];
          const rad = (res.rotationDegrees * Math.PI) / 180;
          const cosR = Math.cos(rad);
          const sinR = Math.sin(rad);
          const localDX = stageDX * cosR + stageDY * sinR;
          const localDY = -stageDX * sinR + stageDY * cosR;

          const rawW = Math.max(minS.width, start.width + cornerMeta.signX * localDX);
          const rawH = Math.max(minS.height, start.height + cornerMeta.signY * localDY);

          const preserveAspect =
            res.kindKey === 'assetRef' ? !shiftKey : shiftKey;

          let newW = rawW;
          let newH = rawH;
          if (preserveAspect) {
            const aspect = start.width / Math.max(1, start.height);
            const scaleW = rawW / Math.max(1, start.width);
            const scaleH = rawH / Math.max(1, start.height);
            const chosenScale =
              Math.abs(scaleW - 1) >= Math.abs(scaleH - 1) ? scaleW : scaleH;
            newW = Math.max(minS.width, start.width * chosenScale);
            newH = Math.max(minS.height, newW / aspect);
            if (newH < minS.height) {
              newH = minS.height;
              newW = Math.max(minS.width, newH * aspect);
            }
          }

          const deltaW = newW - start.width;
          const deltaH = newH - start.height;
          const localShiftX = cornerMeta.signX * deltaW * 0.5;
          const localShiftY = cornerMeta.signY * deltaH * 0.5;
          const worldShiftX = localShiftX * cosR - localShiftY * sinR;
          const worldShiftY = localShiftX * sinR + localShiftY * cosR;
          const newCenterX = start.x + start.width * 0.5 + worldShiftX;
          const newCenterY = start.y + start.height * 0.5 + worldShiftY;
          updatedRect = {
            x: newCenterX - newW * 0.5,
            y: newCenterY - newH * 0.5,
            width: newW,
            height: newH,
          };
        }

        let reflowedChildren: Record<string, BoardRect> = {};
        if (res.kindKey === 'groupFrame' && res.enclosedChildIds.length > 0) {
          const childSet = new Set(res.enclosedChildIds);
          const children = safeNodesRef.current.filter((n) => childSet.has(n.id));
          reflowedChildren = reflowNodesInsideGroupFrame(
            updatedRect,
            children,
            assetsByIdRef.current,
          );
        }

        const next: LiveResizeState = {
          ...res,
          liveRect: updatedRect,
          reflowedChildren,
        };
        liveResizeRef.current = next;
        setLiveResize(next);
        return;
      }

      // 8. Node drag with 6px alignment snap guides (purely local state until mouseup!)
      const drag = liveDragRef.current;
      if (drag) {
        const rawDist = Math.hypot(clientX - drag.startClientX, clientY - drag.startClientY);
        if (!drag.started && rawDist < 3) return;
        const z = cameraRef.current.zoom;
        let dx = (clientX - drag.startClientX) / z;
        let dy = (clientY - drag.startClientY) / z;
        const anchorNode = safeNodesRef.current.find((n) => n.id === drag.anchorNodeId);
        let snapV: number | null = null;
        let snapH: number | null = null;

        if (anchorNode) {
          const threshold = SNAP_THRESHOLD_PX / Math.max(0.2, z);
          const orig = anchorNode.frame;
          const candMinX = orig.x + dx;
          const candMidX = orig.x + orig.width * 0.5 + dx;
          const candMaxX = orig.x + orig.width + dx;
          const candMinY = orig.y + dy;
          const candMidY = orig.y + orig.height * 0.5 + dy;
          const candMaxY = orig.y + orig.height + dy;

          for (const other of safeNodesRef.current) {
            if (drag.movingIds.has(other.id)) continue;
            const f = other.frame;
            if (snapV === null) {
              if (Math.abs(candMinX - f.x) < threshold) {
                dx = f.x - orig.x;
                snapV = f.x;
              } else if (Math.abs(candMidX - (f.x + f.width * 0.5)) < threshold) {
                dx = f.x + f.width * 0.5 - (orig.x + orig.width * 0.5);
                snapV = f.x + f.width * 0.5;
              } else if (Math.abs(candMaxX - (f.x + f.width)) < threshold) {
                dx = f.x + f.width - (orig.x + orig.width);
                snapV = f.x + f.width;
              }
            }
            if (snapH === null) {
              if (Math.abs(candMinY - f.y) < threshold) {
                dy = f.y - orig.y;
                snapH = f.y;
              } else if (Math.abs(candMidY - (f.y + f.height * 0.5)) < threshold) {
                dy = f.y + f.height * 0.5 - (orig.y + orig.height * 0.5);
                snapH = f.y + f.height * 0.5;
              } else if (Math.abs(candMaxY - (f.y + f.height)) < threshold) {
                dy = f.y + f.height - (orig.y + orig.height);
                snapH = f.y + f.height;
              }
            }
            if (snapV !== null && snapH !== null) break;
          }
        }

        const next: LiveDragState = { ...drag, started: true, dx, dy };
        liveDragRef.current = next;
        setLiveDrag(next);
        setGuides({ vertical: snapV, horizontal: snapH });
      }
    };

    const commitAndClearGesture = () => {
      const pan = livePanRef.current;
      const stroke = liveStrokeRef.current;
      const eraser = liveEraserRef.current;
      const portConn = livePortConnRef.current;
      const mq = liveMarqueeRef.current;
      const rot = liveRotateRef.current;
      const res = liveResizeRef.current;
      const drag = liveDragRef.current;

      // Clear refs IMMEDIATELY so duplicate pointerup+mouseup never double-commits
      livePanRef.current = null;
      liveStrokeRef.current = null;
      liveEraserRef.current = null;
      livePortConnRef.current = null;
      liveMarqueeRef.current = null;
      liveRotateRef.current = null;
      liveResizeRef.current = null;
      liveDragRef.current = null;

      setLivePan(null);
      setLiveStroke(null);
      setLiveEraser(null);
      setLivePortConn(null);
      setLiveMarquee(null);
      setLiveRotate(null);
      setLiveResize(null);
      setLiveDrag(null);
      setGuides({ vertical: null, horizontal: null });

      if (pan) {
        persistViewportQuietly(cameraRef.current.center, cameraRef.current.zoom);
      }

      if (stroke && stroke.length >= 2) {
        addInkStroke({
          points: stroke,
          colorHex: inkColorRef.current,
          lineWidth: inkWidthRef.current,
          opacity: 0.92,
          zIndex: 1000 + safeInkStrokesRef.current.length,
        });
      }

      if (eraser && (eraser.strokeIds.size > 0 || eraser.connectorIds.size > 0)) {
        eraseInkAndConnectors(
          Array.from(eraser.strokeIds),
          Array.from(eraser.connectorIds),
        );
      }

      if (portConn) {
        const dropPt = portConn.cursorWorld;
        const targetNode = safeNodesRef.current.find(
          (other) =>
            other.id !== portConn.fromNodeID &&
            dropPt.x >= other.frame.x &&
            dropPt.x <= other.frame.x + other.frame.width &&
            dropPt.y >= other.frame.y &&
            dropPt.y <= other.frame.y + other.frame.height,
        );
        if (targetNode) {
          addConnector({
            fromNodeID: portConn.fromNodeID,
            fromAnchor: portConn.fromAnchor,
            toNodeID: targetNode.id,
            toAnchor: 'auto',
            colorHex: '#5C6672',
            style: connectorStyleRef.current,
            dashed: connectorDashedRef.current,
          });
        }
      }

      if (mq && !mq.started) {
        setSelectedNodeIds([]);
        setSelectedConnectorId(null);
        setSwappingNodeId(null);
        setEditingNoteId(null);
        setEditingGroupId(null);
      }

      if (rot && Math.abs(rot.liveDegrees - rot.startDegrees) > 0.05) {
        const finalAngle = normalizeDegrees(rot.liveDegrees);
        mutateActiveBoard((doc) => ({
          ...doc,
          nodes: doc.nodes.map((n) =>
            n.id === rot.nodeId
              ? { ...n, rotationDegrees: finalAngle, updatedAt: msToCocoaSeconds(Date.now()) }
              : n,
          ),
        }));
      }

      if (res) {
        const finalRect = res.liveRect;
        const finalChildren = res.reflowedChildren;
        mutateActiveBoard((doc) => ({
          ...doc,
          nodes: doc.nodes.map((n) => {
            if (n.id === res.nodeId) {
              return { ...n, frame: finalRect, updatedAt: msToCocoaSeconds(Date.now()) };
            }
            if (finalChildren[n.id]) {
              return { ...n, frame: finalChildren[n.id], updatedAt: msToCocoaSeconds(Date.now()) };
            }
            return n;
          }),
        }));
      }

      if (drag && drag.started) {
        lastNodeDragEndedAtRef.current = Date.now();
        if (Math.hypot(drag.dx, drag.dy) > 0.5) {
          mutateActiveBoard((doc) => ({
            ...doc,
            nodes: doc.nodes.map((n) =>
              drag.movingIds.has(n.id) && !n.isLocked
                ? {
                    ...n,
                    frame: { ...n.frame, x: n.frame.x + drag.dx, y: n.frame.y + drag.dy },
                    updatedAt: msToCocoaSeconds(Date.now()),
                  }
                : n,
            ),
          }));
        }
      }
    };

    const onPointerMove = (e: PointerEvent) => handleMove(e.clientX, e.clientY, e.shiftKey);
    const onMouseMove = (e: MouseEvent) => handleMove(e.clientX, e.clientY, e.shiftKey);
    const onUp = () => commitAndClearGesture();

    window.addEventListener('pointermove', onPointerMove);
    window.addEventListener('pointerup', onUp);
    window.addEventListener('pointercancel', onUp);
    window.addEventListener('mousemove', onMouseMove);
    window.addEventListener('mouseup', onUp);
    window.addEventListener('blur', onUp);
    return () => {
      window.removeEventListener('pointermove', onPointerMove);
      window.removeEventListener('pointerup', onUp);
      window.removeEventListener('pointercancel', onUp);
      window.removeEventListener('mousemove', onMouseMove);
      window.removeEventListener('mouseup', onUp);
      window.removeEventListener('blur', onUp);
    };
  }, [
    isAnyGestureActive,
    clientToWorld,
    clientToStage,
    sweepEraseAtWorldPoint,
    persistViewportQuietly,
    addInkStroke,
    eraseInkAndConnectors,
    addConnector,
    mutateActiveBoard,
    setSelectedNodeIds,
    setSwappingNodeId,
  ]);

  if (!activeBoard) return null;

  const currentExportOptions = (overrideFormat?: BoardImageFormat): MoodboardExportOptions => ({
    scale: Number(exportScale),
    format: overrideFormat ?? exportFormat,
    includeAnnotations: exportAnnotations,
    includePaletteStrip: exportPalette,
    darkAppearance: exportDark,
    containerWidth: stageSize.width,
  });

  const hasExportableContent = safeNodes.length > 0 || safeInkStrokes.length > 0;

  const handleExportImage = async (overrideFormat?: BoardImageFormat) => {
    if (exporting) return;
    if (!hasExportableContent) {
      pushToast({ message: '当前画布暂无可导出的素材或批注', tone: 'info', durationMs: 2400 });
      return;
    }
    const fmt = overrideFormat ?? exportFormat;
    const ext = fmt === 'png' ? 'png' : 'jpg';
    const stem = sanitizeExportFileName(activeBoard.title);
    setExporting(true);
    try {
      await useMoodboardStore.getState().flushPendingSaves();
      const dest = await transport.saveFileDialog(`${stem}.${ext}`, [
        { name: fmt.toUpperCase(), extensions: [ext] },
      ]);
      if (!dest) return;
      const latestBoard = useMoodboardStore.getState().activeBoard ?? activeBoard;
      const bytes = await transport.exportBoardImageFile(
        latestBoard,
        currentExportOptions(fmt),
        dest,
      );
      setExportOpen(false);
      pushToast({
        message: `已导出 ${exportScale}× ${fmt.toUpperCase()}（${Math.round(bytes / 1024)} KB）`,
        tone: 'success',
      });
    } catch (err) {
      pushToast({
        message: `导出图片失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setExporting(false);
    }
  };

  const handleCopyClipboard = async () => {
    if (exporting) return;
    if (!hasExportableContent) {
      pushToast({ message: '当前画布暂无可导出的素材或批注', tone: 'info', durationMs: 2400 });
      return;
    }
    setExporting(true);
    try {
      await useMoodboardStore.getState().flushPendingSaves();
      const latestBoard = useMoodboardStore.getState().activeBoard ?? activeBoard;
      await transport.copyBoardImageToClipboard(latestBoard, {
        ...currentExportOptions('png'),
        format: 'png',
      });
      setExportOpen(false);
      pushToast({
        message: '已复制高清情绪板到剪贴板，可直接 Ctrl+V 粘贴',
        tone: 'success',
      });
    } catch (err) {
      pushToast({
        message: `复制图片失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setExporting(false);
    }
  };

  const handleExportFigmaBridge = async () => {
    if (exporting) return;
    if (!hasExportableContent) {
      pushToast({ message: '当前画布暂无可导出的素材或批注', tone: 'info', durationMs: 2400 });
      return;
    }
    const stem = sanitizeExportFileName(activeBoard.title);
    setExporting(true);
    try {
      await useMoodboardStore.getState().flushPendingSaves();
      const dest = await transport.saveFileDialog(`${stem}.charkleboard`, [
        { name: 'Charkle Figma Bridge', extensions: ['charkleboard'] },
      ]);
      if (!dest) return;
      const latestBoard = useMoodboardStore.getState().activeBoard ?? activeBoard;
      const report = await transport.exportBoardFigmaBridge(
        latestBoard,
        currentExportOptions('png'),
        dest,
      );
      setExportOpen(false);
      pushToast({
        message: `已导出 .charkleboard（${report.objectCount} 对象 / ${report.imageCount} 图片 / ${report.connectorCount} 连线）`,
        tone: 'success',
        durationMs: 4800,
      });
    } catch (err) {
      pushToast({
        message: `导出 .charkleboard 失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setExporting(false);
    }
  };

  const handleCopyColorHex = (hex: string) => {
    const upper = hex.toUpperCase();
    void navigator.clipboard?.writeText(upper).catch(() => {});
    setCopiedPaletteHex(upper);
    window.setTimeout(() => {
      setCopiedPaletteHex((prev) => (prev === upper ? null : prev));
    }, 1200);
    pushToast({ message: `已复制色值 ${upper}`, tone: 'info', durationMs: 1800 });
  };

  const handleSearchColorHex = (hex: string) => {
    const upper = hex.toUpperCase();
    const boardId = activeBoard.id;
    setDestination({ type: 'allItems' });
    setVisualFilterBarOpen(true);
    void setCriteria({ selectedColorHex: upper }, { type: 'allItems' }).catch(() => {});
    pushToast({
      message: `已按色值 ${upper} 筛选素材库`,
      tone: 'info',
      actionLabel: '返回情绪板',
      durationMs: 5500,
      onAction: () => setDestination({ type: 'moodboard', id: boardId }),
    });
  };

  const handleCanvasDrop = async (e: React.DragEvent) => {
    e.preventDefault();
    try {
      const dropPt = clientToWorld(e.clientX, e.clientY);
      const candId = e.dataTransfer.getData(CANDIDATE_DRAG_MIME);
      if (candId) {
        addAssetNodeAt(candId, dropPt, assetsById.get(candId) ?? null);
        return;
      }
      const files = Array.from(e.dataTransfer.files);
      if (files.length > 0) {
        let offset = 0;
        for (const file of files) {
          const dataUrl = await new Promise<string>((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(String(reader.result ?? ''));
            reader.onerror = () => reject(reader.error ?? new Error('读取文件失败'));
            reader.readAsDataURL(file);
          });
          const base64 = dataUrl.includes(',') ? dataUrl.split(',')[1] : dataUrl;
          if (base64) {
            const created = await ingestImageBase64(base64, file.name, null, null);
            if (created[0]) {
              addAssetNodeAt(
                created[0].id,
                { x: dropPt.x + offset * 28, y: dropPt.y + offset * 24 },
                created[0],
              );
              offset += 1;
            }
          }
        }
      }
    } catch (err) {
      pushToast({
        message: `拖入素材失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    }
  };

  const revealAssetInLibrary = async (assetId: string) => {
    try {
      let asset = assetsById.get(assetId) ?? null;
      if (!asset) {
        asset = await transport.fetchAsset(assetId).catch(() => null);
      }
      if (!asset) {
        pushToast({ message: '素材库中未找到此素材', tone: 'error' });
        return;
      }

      const targetDest: SidebarDestination = asset.isTrashed
        ? { type: 'trash' }
        : asset.folderID
          ? { type: 'folder', id: asset.folderID }
          : { type: 'inbox' };

      const boardId = activeBoard.id;
      const boardTitle = activeBoard.title;
      setDestination(targetDest, { preserveSelection: true });
      await clearVisualFilters(targetDest);
      setSelection([asset.id], asset.id);
      requestGalleryReveal({
        assetId: asset.id,
        sourceBoardId: boardId,
        sourceBoardTitle: boardTitle,
      });
      pushToast({
        message: `已在素材库中定位「${asset.title}」`,
        tone: 'info',
        actionLabel: '返回情绪板',
        durationMs: 6500,
        onAction: () => {
          setDestination({ type: 'moodboard', id: boardId });
        },
      });
    } catch (err) {
      pushToast({
        message: `定位失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    }
  };

  const showCanvasDropOverlay =
    (osFileDrop.active && osFileDrop.target?.kind === 'moodboardCanvas') ||
    (pointerDrag?.kind === 'candidate' && pointerTarget?.kind === 'moodboardCanvas');

  const activeDraggingEditorialId =
    pointerDrag?.kind === 'editorialNode' ? pointerDrag.nodeId : null;
  const activeHoverEditorialIdx =
    pointerDrag?.kind === 'editorialNode' && pointerTarget?.kind === 'editorialNode'
      ? pointerTarget.orderIndex
      : null;

  const orderedRenderNodes = useMemo(
    () =>
      [...safeNodes].sort((a, b) => {
        const ag = 'groupFrame' in a.kind ? 0 : 1;
        const bg = 'groupFrame' in b.kind ? 0 : 1;
        if (ag !== bg) return ag - bg;
        if (a.zIndex !== b.zIndex) return a.zIndex - b.zIndex;
        return a.editorialOrder - b.editorialOrder;
      }),
    [safeNodes],
  );

  const editorialOrderIndexMap = useMemo(
    () => new Map<string, number>((editorialSolved?.orderedNodeIds ?? []).map((id, idx) => [id, idx])),
    [editorialSolved],
  );

  // Freeform world camera CSS transform & architectural dot grid math
  const worldTx = stageSize.width * 0.5 - camera.center.x * camera.zoom;
  const worldTy = stageSize.height * 0.5 - camera.center.y * camera.zoom;

  const dotGridStyle = useMemo<React.CSSProperties>(() => {
    const z = camera.zoom;
    let worldStep = 28;
    while (worldStep * z < 16) worldStep *= 2;
    while (worldStep * z > 56) worldStep *= 0.5;
    const step = Math.max(16, Math.min(64, Math.round(worldStep * z * 2) / 2));
    const dotRadius = Math.max(0.8, Math.min(1.5, z));
    const alpha = z < 0.35 ? 0.055 : 0.11;
    const dotColor = isDark ? `rgba(255,255,255,${alpha})` : `rgba(0,0,0,${alpha})`;
    const phaseX = positiveMod(worldTx, step);
    const phaseY = positiveMod(worldTy, step);
    return {
      backgroundImage: `radial-gradient(circle, ${dotColor} ${dotRadius}px, transparent ${dotRadius + 0.35}px)`,
      backgroundSize: `${step}px ${step}px`,
      backgroundPosition: `${phaseX - step * 0.5}px ${phaseY - step * 0.5}px`,
    };
  }, [camera.zoom, isDark, worldTx, worldTy]);

  const allowNodeHitTesting =
    isEditorial || (tool !== 'ink' && tool !== 'eraser' && tool !== 'hand' && !spacePressed);

  const visibleConnectors = useMemo(
    () =>
      safeConnectors.filter((c) => !liveEraser || !liveEraser.connectorIds.has(c.id)),
    [safeConnectors, liveEraser],
  );

  const visibleInkStrokes = useMemo(
    () =>
      safeInkStrokes.filter((s) => !liveEraser || !liveEraser.strokeIds.has(s.id)),
    [safeInkStrokes, liveEraser],
  );

  const screenHandleNodes = useMemo(() => {
    if (
      isEditorial ||
      tool === 'ink' ||
      tool === 'eraser' ||
      tool === 'hand' ||
      spacePressed ||
      livePan ||
      cameraAnimated
    ) {
      return [];
    }
    if (tool === 'connector') return orderedRenderNodes;
    if (selectedNodeIds.length === 0 && !hoveredNodeId) return [];
    const selSet = new Set(selectedNodeIds);
    return orderedRenderNodes.filter((n) => selSet.has(n.id) || n.id === hoveredNodeId);
  }, [
    isEditorial,
    tool,
    spacePressed,
    livePan,
    cameraAnimated,
    orderedRenderNodes,
    selectedNodeIds,
    hoveredNodeId,
  ]);

  const startResizeHandle = (
    e: React.PointerEvent,
    node: BoardNode,
    corner: ResizeCorner | null,
    sideEdge: -1 | 0 | 1,
  ) => {
    if (e.button !== 0 || node.isLocked) return;
    e.preventDefault();
    e.stopPropagation();
    try {
      (e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId);
    } catch {
      // ignore synthetic events
    }
    const enclosedChildIds = 'groupFrame' in node.kind ? enclosedChildIdsFor(node) : [];
    const next: LiveResizeState = {
      nodeId: node.id,
      corner,
      sideEdge,
      startClientX: e.clientX,
      startClientY: e.clientY,
      origRect: { ...node.frame },
      liveRect: { ...node.frame },
      rotationDegrees: node.rotationDegrees ?? 0,
      kindKey: nodeKindKey(node.kind),
      enclosedChildIds,
      reflowedChildren: {},
    };
    liveResizeRef.current = next;
    setLiveResize(next);
  };

  const startRotationHandle = (
    e: React.PointerEvent,
    node: BoardNode,
    screenCenter: BoardPoint,
  ) => {
    if (e.button !== 0 || node.isLocked) return;
    e.preventDefault();
    e.stopPropagation();
    try {
      (e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId);
    } catch {
      // ignore synthetic events
    }
    const el = stageRef.current;
    const rect = el?.getBoundingClientRect();
    const centerClientX = (rect?.left ?? 0) + screenCenter.x;
    const centerClientY = (rect?.top ?? 0) + screenCenter.y;
    const dragStartAngle =
      (Math.atan2(e.clientY - centerClientY, e.clientX - centerClientX) * 180) / Math.PI;
    const startDegrees = node.rotationDegrees ?? 0;
    const next: LiveRotateState = {
      nodeId: node.id,
      centerScreenX: centerClientX,
      centerScreenY: centerClientY,
      startDegrees,
      dragStartAngle,
      liveDegrees: startDegrees,
    };
    liveRotateRef.current = next;
    setLiveRotate(next);
  };

  const startPortDrag = (
    e: React.PointerEvent,
    node: BoardNode,
    anchor: ConnectorAnchor,
    startWorld: BoardPoint,
  ) => {
    if (e.button !== 0) return;
    e.preventDefault();
    e.stopPropagation();
    try {
      (e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId);
    } catch {
      // ignore
    }
    const next: LivePortConnectorState = {
      fromNodeID: node.id,
      fromAnchor: anchor,
      startWorld,
      cursorWorld: startWorld,
    };
    livePortConnRef.current = next;
    setLivePortConn(next);
  };

  const showTransformPill = tool === 'select' && selectedNodeIds.length > 0;
  const dockLayout = resolveMoodboardDockLayout(stageSize.width);
  const showEditorialStyleInHeader = stageSize.width + (inspectorOpen ? 300 : 0) >= 580;

  return (
    <div
      data-testid="moodboard-studio-view"
      className="charkle-gallery-surface flex-1 min-w-0 min-h-0 h-full flex flex-col bg-[var(--bg-gallery)] overflow-hidden"
    >
      {/* Top Studio Header Bar */}
      <header className="shrink-0 h-[48px] px-3.5 border-b border-[var(--border-hairline)] bg-[var(--bg-elevated)]/85 flex items-center justify-between gap-2 select-none overflow-hidden">
        <div className="flex items-center gap-1.5 min-w-0 flex-1">
          <Button
            variant="ghost"
            size="xs"
            aria-label="返回情绪板列表"
            title="返回情绪板列表"
            className="shrink-0 whitespace-nowrap"
            onClick={() => setDestination({ type: 'moodboardsHome' })}
          >
            <ArrowLeft size={14} />
            {!dockLayout.compactHeader && <span>情绪板</span>}
          </Button>
          <input
            type="text"
            value={titleDraft}
            aria-label="情绪板标题"
            onChange={(e) => setTitleDraft(e.target.value)}
            onBlur={() => {
              const trimmed = titleDraft.trim();
              if (trimmed && trimmed !== activeBoard.title) {
                mutateActiveBoard((doc) => ({ ...doc, title: trimmed }), { immediateSave: true });
              }
            }}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.nativeEvent.isComposing) e.currentTarget.blur();
            }}
            className="h-7 px-2 rounded-[var(--radius-card-inner)] bg-transparent hover:bg-[var(--bg-subtle)] focus:bg-[var(--bg-inspector-field)] border border-transparent focus:border-[var(--accent)] text-[14px] font-semibold text-[var(--text-primary)] outline-none min-w-[72px] flex-1 max-w-[220px] truncate"
          />

          <SegmentedControl<'autoEditorial' | 'freeform'>
            value={isEditorial ? 'autoEditorial' : 'freeform'}
            onChange={(mode) => switchBoardMode(mode, stageSize.width, assetsById)}
            ariaLabel="情绪板画布模式"
            size="xs"
            className="shrink-0"
            options={[
              { value: 'autoEditorial', label: '自动编排', icon: <LayoutGrid size={12.5} /> },
              { value: 'freeform', label: '自由画布', icon: <Layers size={12.5} /> },
            ]}
          />

          {isEditorial && showEditorialStyleInHeader && (
            <SegmentedControl<EditorialStyle>
              value={editorialCfg.style}
              onChange={(style) =>
                switchBoardMode('autoEditorial', stageSize.width, assetsById, { style })
              }
              ariaLabel="自动编排风格"
              size="xs"
              className="shrink-0"
              options={[
                { value: 'balanced', label: '均衡' },
                { value: 'magazine', label: '杂志' },
                { value: 'compact', label: '紧凑' },
              ]}
            />
          )}
        </div>

        <div className="flex items-center gap-1 shrink-0">
          <Button
            variant="ghost"
            size="icon"
            disabled={historyPast.length === 0}
            onClick={undo}
            aria-label="撤销"
            title="撤销 (Ctrl+Z)"
            className="shrink-0"
          >
            <Undo2 size={14.5} />
          </Button>
          <Button
            variant="ghost"
            size="icon"
            disabled={historyFuture.length === 0}
            onClick={redo}
            aria-label="重做"
            title="重做 (Ctrl+Shift+Z)"
            className="shrink-0"
          >
            <Redo2 size={14.5} />
          </Button>

          <Button
            variant="secondary"
            size="xs"
            aria-label="智能策展"
            onClick={() => setGenOpen(true)}
            title="打开 AI 情绪板策展工作台"
            className="shrink-0 whitespace-nowrap"
          >
            <Sparkles size={12.5} />
            {!dockLayout.compactHeader && <span>智能策展</span>}
          </Button>

          <Button
            ref={exportBtnRef}
            variant="primary"
            size="xs"
            aria-label="导出"
            title="导出情绪板"
            onClick={() => setExportOpen((v) => !v)}
            className="shrink-0 whitespace-nowrap"
          >
            <Download size={13} />
            {dockLayout.showExportLabel && <span>导出</span>}
          </Button>

          <Button
            variant="ghost"
            size="icon"
            active={inspectorOpen}
            onClick={toggleInspector}
            aria-label="切换右侧检查器"
            title="显示 / 隐藏右侧检查器 (Ctrl+I)"
            className="shrink-0"
          >
            <PanelRight size={15} />
          </Button>
        </div>
      </header>

      {/* Main Workspace: Stage + Collapsible 300px Right Rail */}
      <div className="flex-1 min-w-0 min-h-0 flex overflow-hidden relative">
        <div
          ref={stageRef}
          data-testid="moodboard-canvas-stage"
          data-board-mode={isEditorial ? 'autoEditorial' : 'freeform'}
          onDragOver={(e) => e.preventDefault()}
          onDrop={(e) => void handleCanvasDrop(e)}
          onContextMenu={(e) => {
            if (!e.currentTarget.contains(e.target as Node)) return;
            if ((e.target as HTMLElement).closest('[data-board-node-id]')) return;
            e.preventDefault();
            setContextMenu({
              kind: 'canvas',
              worldPt: clientToWorld(e.clientX, e.clientY),
              x: e.clientX,
              y: e.clientY,
            });
          }}
          onMouseDown={(e) => {
            // Isolate portaled UI (<Popover> menus, modals) from bubbling into canvas stage
            if (!e.currentTarget.contains(e.target as Node)) return;
            // Middle-mouse button pans from anywhere in Freeform
            if (!isEditorial && e.button === 1) {
              e.preventDefault();
              const pan: LivePanState = {
                startClientX: e.clientX,
                startClientY: e.clientY,
                startCenter: { ...cameraRef.current.center },
                fromSpace: false,
              };
              livePanRef.current = pan;
              setLivePan(pan);
              return;
            }

            // Space+drag or Hand tool pans even when cursor starts over a node
            if (!isEditorial && e.button === 0 && (tool === 'hand' || spaceHeldRef.current || e.altKey)) {
              e.preventDefault();
              const pan: LivePanState = {
                startClientX: e.clientX,
                startClientY: e.clientY,
                startCenter: { ...cameraRef.current.center },
                fromSpace: spaceHeldRef.current,
              };
              livePanRef.current = pan;
              setLivePan(pan);
              return;
            }

            if (!isEditorial && tool === 'ink' && e.button === 0) {
              const pt = clientToWorld(e.clientX, e.clientY);
              const init: InkStrokePoint[] = [{ x: pt.x, y: pt.y, pressure: 0.6 }];
              liveStrokeRef.current = init;
              setLiveStroke(init);
              return;
            }

            if (!isEditorial && tool === 'eraser' && e.button === 0) {
              const init: LiveEraserState = { strokeIds: new Set(), connectorIds: new Set() };
              liveEraserRef.current = init;
              setLiveEraser(init);
              sweepEraseAtWorldPoint(clientToWorld(e.clientX, e.clientY));
              return;
            }

            if ((e.target as HTMLElement).closest('[data-board-node-id]')) return;
            if ((e.target as HTMLElement).closest('[data-stage-floating-ui="true"]')) return;

            if (e.button === 0) {
              setContextMenu(null);
              setEditingConnector(null);
              setEditingNoteId(null);
              setEditingGroupId(null);
              setPendingConnector(null);
              setSelectedConnectorId(null);
              if (!isEditorial) {
                const startScreen = clientToStage(e.clientX, e.clientY);
                const mq: LiveMarqueeState = {
                  startScreen,
                  curScreen: startScreen,
                  started: false,
                };
                liveMarqueeRef.current = mq;
                setLiveMarquee(mq);
              } else {
                setSelectedNodeIds([]);
                setSwappingNodeId(null);
              }
            }
          }}
          className={[
            'relative flex-1 min-w-0 min-h-0 bg-[var(--bg-gallery)] select-none',
            isEditorial ? 'overflow-y-auto charkle-scroll' : 'overflow-hidden',
            !isEditorial && (tool === 'hand' || spacePressed || livePan)
              ? livePan
                ? 'cursor-grabbing'
                : 'cursor-grab'
              : !isEditorial && (tool === 'ink' || tool === 'eraser')
                ? 'cursor-crosshair'
                : 'cursor-default',
          ].join(' ')}
        >
          {/* 1. Architectural Dot Grid Layer (Freeform only) */}
          {!isEditorial && (
            <div
              data-testid="freeform-dot-grid"
              aria-hidden="true"
              style={dotGridStyle}
              className="pointer-events-none absolute inset-0 z-0"
            />
          )}

          {/* 2. Empty Board Placeholder */}
          {safeNodes.length === 0 && visibleInkStrokes.length === 0 && (
            <div className="pointer-events-none absolute inset-0 z-10 flex flex-col items-center justify-center gap-2.5 text-center px-8">
              <Layers size={34} strokeWidth={1.4} className="text-[var(--text-tertiary)]/70" />
              <div className="text-[14px] font-medium text-[var(--text-secondary)]">
                把素材拖进来，或从右侧候选池点击加入
              </div>
              <p className="text-[12px] text-[var(--text-tertiary)] max-w-[400px]">
                支持直接从资源管理器拖入图片文件，自动归档至收件箱并上板
              </p>
            </div>
          )}

          {/* 3. World Container (Single GPU-composited translate3d + scale layer) */}
          <div
            style={
              isEditorial
                ? {
                    position: 'relative',
                    width: '100%',
                    height: Math.max((editorialSolved?.contentSize.height ?? 560) + 104, 560),
                  }
                : {
                    position: 'absolute',
                    inset: 0,
                    transformOrigin: '0 0',
                    transform: `translate3d(${worldTx}px, ${worldTy}px, 0) scale(${camera.zoom})`,
                    transition: cameraAnimated
                      ? 'transform 220ms var(--ease-out-strong)'
                      : 'none',
                  }
            }
          >
            {/* Smart 6px Alignment Guides */}
            {!isEditorial && guides.vertical !== null && (
              <div
                aria-hidden="true"
                className="pointer-events-none absolute top-[-4000px] bottom-[-4000px] w-px border-l border-dashed border-[var(--accent)]/75 z-[900]"
                style={{ left: guides.vertical }}
              />
            )}
            {!isEditorial && guides.horizontal !== null && (
              <div
                aria-hidden="true"
                className="pointer-events-none absolute left-[-4000px] right-[-4000px] h-px border-t border-dashed border-[var(--accent)]/75 z-[900]"
                style={{ top: guides.horizontal }}
              />
            )}

            {/* Render All 4 Node Types */}
            {orderedRenderNodes.map((node) => {
              const rect = effectiveFramesMap.get(node.id) ?? node.frame;
              const rot = effectiveRotation(node);
              const selected = selectedNodeIds.includes(node.id);
              const isSwapTarget = swappingNodeId === node.id;
              const edIdx = editorialOrderIndexMap.get(node.id) ?? 0;

              let rippleOffsetY = 0;
              let rippleDelayMs = 0;
              if (
                isEditorial &&
                activeDraggingEditorialId &&
                activeHoverEditorialIdx !== null &&
                node.id !== activeDraggingEditorialId
              ) {
                const dist = Math.abs(edIdx - activeHoverEditorialIdx);
                if (dist > 0 && dist <= 4) {
                  rippleOffsetY = Math.round(6 * Math.pow(0.7, dist));
                  rippleDelayMs = 24 * dist;
                }
              }

              const nodeDragLabel =
                'assetRef' in node.kind
                  ? (assetsById.get(node.kind.assetRef.assetID)?.title ?? '素材')
                  : 'note' in node.kind
                    ? (node.kind.note.title || '便签')
                    : 'groupFrame' in node.kind
                      ? (node.kind.groupFrame.title || '分组')
                      : '色卡条';

              const enclosedCount =
                'groupFrame' in node.kind
                  ? safeNodes.filter(
                      (other) =>
                        other.id !== node.id &&
                        !('groupFrame' in other.kind) &&
                        isRectInsideGroup(other.frame, node.frame),
                    ).length
                  : 0;

              const handleNodeMouseDown = (e: React.MouseEvent) => {
                if (!allowNodeHitTesting && tool !== 'connector') return;
                if (e.button !== 0) return;
                if ((e.target as HTMLElement).closest('input, textarea, button')) return;
                e.stopPropagation();
                setContextMenu(null);
                setEditingNoteId((cur) => (cur && cur !== node.id ? null : cur));
                setEditingGroupId((cur) => (cur && cur !== node.id ? null : cur));

                // Connector tool mode (supports pinpoint normalized internal anchor callouts)
                if (tool === 'connector') {
                  const pt = clientToWorld(e.clientX, e.clientY);
                  const norm: BoardPoint = {
                    x: Math.max(0.02, Math.min(0.98, (pt.x - rect.x) / Math.max(1, rect.width))),
                    y: Math.max(0.02, Math.min(0.98, (pt.y - rect.y) / Math.max(1, rect.height))),
                  };
                  if (!pendingConnector) {
                    setPendingConnector({ fromNodeID: node.id, fromNormalizedPoint: norm });
                  } else if (pendingConnector.fromNodeID !== node.id) {
                    addConnector({
                      fromNodeID: pendingConnector.fromNodeID,
                      fromAnchor: 'auto',
                      fromNormalizedPoint: pendingConnector.fromNormalizedPoint,
                      toNodeID: node.id,
                      toAnchor: 'auto',
                      toNormalizedPoint: norm,
                      label: null,
                      colorHex: '#5C6672',
                      style: connectorStyle,
                      dashed: connectorDashed,
                    });
                    setPendingConnector(null);
                  }
                  return;
                }

                const nextSelected =
                  e.ctrlKey || e.metaKey || e.shiftKey
                    ? selected
                      ? selectedNodeIds.filter((id) => id !== node.id)
                      : [...selectedNodeIds, node.id]
                    : selected
                      ? selectedNodeIds
                      : [node.id];
                setSelectedNodeIds(nextSelected);
                setSelectedConnectorId(null);

                // Auto Editorial uses beginPointerDrag exclusively (no dual-drag collision)
                if (isEditorial || node.isLocked) return;

                const movingIds = new Set(nextSelected);
                if ('groupFrame' in node.kind) {
                  for (const cid of enclosedChildIdsFor(node)) {
                    movingIds.add(cid);
                  }
                }
                const dragState: LiveDragState = {
                  anchorNodeId: node.id,
                  movingIds,
                  startClientX: e.clientX,
                  startClientY: e.clientY,
                  dx: 0,
                  dy: 0,
                  started: false,
                };
                liveDragRef.current = dragState;
                setLiveDrag(dragState);
              };

              const isBeingDirectlyManipulated =
                Boolean(liveDrag?.started && liveDrag.movingIds.has(node.id)) ||
                Boolean(liveResize && (liveResize.nodeId === node.id || liveResize.reflowedChildren[node.id])) ||
                Boolean(liveRotate && liveRotate.nodeId === node.id);

              return (
                <div
                  key={node.id}
                  data-board-node-id={node.id}
                  data-editorial-order-index={edIdx}
                  onMouseEnter={() => setHoveredNodeId(node.id)}
                  onMouseLeave={() =>
                    setHoveredNodeId((prev) => (prev === node.id ? null : prev))
                  }
                  onPointerDown={(e) => {
                    if (!isEditorial || node.isLocked || e.button !== 0 || tool !== 'select') {
                      return;
                    }
                    if ((e.target as HTMLElement).closest('input, textarea, button')) return;
                    beginPointerDrag(e, {
                      kind: 'editorialNode',
                      nodeId: node.id,
                      title: nodeDragLabel,
                    });
                  }}
                  onContextMenu={(e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    const targetIds =
                      selected && selectedNodeIds.length > 1 ? [...selectedNodeIds] : [node.id];
                    if (!selected) setSelectedNodeIds([node.id]);
                    const swatchHex =
                      (e.target as HTMLElement).closest<HTMLElement>('[data-swatch-hex]')?.dataset
                        .swatchHex ?? null;
                    setContextMenu({
                      kind: 'node',
                      nodeId: node.id,
                      targetIds,
                      swatchHex,
                      x: e.clientX,
                      y: e.clientY,
                    });
                  }}
                  onDoubleClick={(e) => {
                    if ((e.target as HTMLElement).closest('input, textarea, button')) return;
                    if ('note' in node.kind && !node.isLocked && !wasRecentPointerDrag()) {
                      e.stopPropagation();
                      setSelectedNodeIds([node.id]);
                      setEditingGroupId(null);
                      setEditingNoteId(node.id);
                      return;
                    }
                    if ('assetRef' in node.kind && !wasRecentPointerDrag()) {
                      const box = (e.currentTarget as HTMLElement).getBoundingClientRect();
                      openBoardAsset(node.kind.assetRef.assetID, {
                        left: box.left,
                        top: box.top,
                        width: box.width,
                        height: box.height,
                      });
                    }
                  }}
                  onMouseDown={handleNodeMouseDown}
                  style={{
                    position: 'absolute',
                    left: 0,
                    top: 0,
                    width: rect.width,
                    height: rect.height,
                    zIndex: 'groupFrame' in node.kind ? 1 : 10 + Math.max(0, node.zIndex),
                    opacity: activeDraggingEditorialId === node.id ? 0.52 : 1,
                    pointerEvents: allowNodeHitTesting || tool === 'connector' ? 'auto' : 'none',
                    transform: `translate3d(${rect.x}px, ${rect.y + rippleOffsetY}px, 0) rotate(${rot}deg)`,
                    transition: isBeingDirectlyManipulated
                      ? 'none'
                      : `transform var(--duration-move) var(--ease-out-strong) ${rippleDelayMs}ms, opacity 140ms var(--ease-out)`,
                  }}
                  className={[
                    'group rounded-[var(--radius-card-outer)]',
                    isEditorial && !node.isLocked ? 'cursor-grab active:cursor-grabbing' : '',
                    pointerDrag?.kind === 'editorialNode' &&
                    pointerTarget?.kind === 'editorialNode' &&
                    pointerTarget.nodeId === node.id
                      ? 'ring-2 ring-[var(--accent)]/80'
                      : '',
                  ].join(' ')}
                >
                  {/* 1. GroupFrame (Safe palette lookup + click-to-drag title / double-click rename) */}
                  {'groupFrame' in node.kind && (() => {
                    const gData = node.kind.groupFrame;
                    const theme = getGroupTintPalette(gData.tint);
                    const isEditingGroup = editingGroupId === node.id;
                    return (
                      <div
                        style={{
                          backgroundColor: isDark ? theme.bgDark : theme.bgLight,
                          borderColor: selected ? 'var(--accent)' : theme.accent,
                          borderWidth: selected ? 1.8 : 1.15,
                        }}
                        className="w-full h-full rounded-[var(--radius-card-outer)] border border-solid flex flex-col overflow-hidden"
                      >
                        <div
                          style={{
                            backgroundColor: isDark ? theme.headerDark : theme.headerLight,
                          }}
                          className="px-3 py-2 flex items-center gap-1.5"
                        >
                          <Grid2x2 size={11} style={{ color: theme.accent }} className="shrink-0" />
                          {enclosedCount > 0 && (
                            <span
                              style={{ color: theme.accent }}
                              className="text-[11px] font-bold charkle-tabular shrink-0 select-none"
                            >
                              {enclosedCount} ·
                            </span>
                          )}
                          {isEditingGroup ? (
                            <input
                              type="text"
                              autoFocus
                              value={gData.title}
                              placeholder="分组名称"
                              onMouseDown={(e) => e.stopPropagation()}
                              onBlur={() =>
                                setEditingGroupId((cur) => (cur === node.id ? null : cur))
                              }
                              onKeyDown={(e) => {
                                if ((e.key === 'Enter' && !e.nativeEvent.isComposing) || e.key === 'Escape') {
                                  e.preventDefault();
                                  e.stopPropagation();
                                  e.currentTarget.blur();
                                  setEditingGroupId(null);
                                }
                              }}
                              onChange={(e) => {
                                const val = e.target.value;
                                mutateActiveBoard((doc) => ({
                                  ...doc,
                                  nodes: doc.nodes.map((n) =>
                                    n.id === node.id && 'groupFrame' in n.kind
                                      ? {
                                          ...n,
                                          kind: { groupFrame: { ...n.kind.groupFrame, title: val } },
                                        }
                                      : n,
                                  ),
                                }));
                              }}
                              style={{ color: theme.accent }}
                              className="bg-transparent text-[12px] font-semibold outline-none flex-1 min-w-0"
                            />
                          ) : (
                            <span
                              onDoubleClick={(e) => {
                                if (node.isLocked) return;
                                e.stopPropagation();
                                setSelectedNodeIds([node.id]);
                                setEditingNoteId(null);
                                setEditingGroupId(node.id);
                              }}
                              style={{ color: theme.accent }}
                              className="text-[12px] font-semibold truncate flex-1 min-w-0 select-none"
                              title="双击重命名分组"
                            >
                              {gData.title || '分组名称'}
                            </span>
                          )}
                          <div
                            className={[
                              'flex items-center gap-1.5 shrink-0 transition-opacity duration-150',
                              selected ? 'opacity-100' : 'opacity-0 group-hover:opacity-100',
                            ].join(' ')}
                          >
                            {enclosedCount > 0 && (
                              <button
                                type="button"
                                onMouseDown={(e) => e.stopPropagation()}
                                onClick={(e) => {
                                  e.stopPropagation();
                                  reflowGroupFrameNow(node.id);
                                }}
                                style={{ color: theme.accent }}
                                className="charkle-pressable px-1.5 py-0.5 rounded-full bg-current/12 text-[10px] font-semibold cursor-pointer"
                                title="按当前框尺寸实时缩放并重排框内所有素材"
                              >
                                自适应排布
                              </button>
                            )}
                            <div className="flex items-center gap-1">
                              {(Object.keys(GROUP_TINT_PALETTE) as GroupTint[]).map((tKey) => (
                                <button
                                  key={tKey}
                                  type="button"
                                  title={GROUP_TINT_PALETTE[tKey].label}
                                  onMouseDown={(e) => e.stopPropagation()}
                                  onClick={(e) => {
                                    e.stopPropagation();
                                    mutateActiveBoard((doc) => ({
                                      ...doc,
                                      nodes: doc.nodes.map((n) =>
                                        n.id === node.id && 'groupFrame' in n.kind
                                          ? { ...n, kind: { groupFrame: { ...n.kind.groupFrame, tint: tKey } } }
                                          : n,
                                      ),
                                    }));
                                  }}
                                  style={{ backgroundColor: GROUP_TINT_PALETTE[tKey].accent }}
                                  className={[
                                    'h-2.5 w-2.5 rounded-full cursor-pointer',
                                    gData.tint === tKey ? 'ring-1 ring-white' : '',
                                  ].join(' ')}
                                />
                              ))}
                            </div>
                          </div>
                        </div>
                      </div>
                    );
                  })()}

                  {/* 2. AssetRef (macOS BoardAssetNodeView parity + deleted/swatch/error resilience) */}
                  {'assetRef' in node.kind && (() => {
                    const refKind = node.kind.assetRef;
                    const asset = assetsById.get(refKind.assetID);
                    const isMissingAsset = libraryBootstrapped && !asset;
                    const crop = refKind.crop;
                    const hasCrop = Boolean(
                      !isMissingAsset &&
                        crop &&
                        crop.width > 0.05 &&
                        crop.height > 0.05 &&
                        crop.width * crop.height < 0.99,
                    );
                    const cropStyle: React.CSSProperties =
                      hasCrop && crop
                        ? {
                            width: `${100 / crop.width}%`,
                            height: `${100 / crop.height}%`,
                            transform: `translate(-${crop.x * 100}%, -${crop.y * 100}%)`,
                            maxWidth: 'none',
                          }
                        : { width: '100%', height: '100%' };
                    const mediaFlipTransform = isMissingAsset
                      ? undefined
                      : `scaleX(${node.flipHorizontal ? -1 : 1}) scaleY(${node.flipVertical ? -1 : 1})`;

                    return (
                      <div
                        style={{
                          boxShadow: selected
                            ? isDark
                              ? '0 4px 18px rgba(0,0,0,0.45)'
                              : '0 4px 16px rgba(0,0,0,0.12)'
                            : isDark
                              ? '0 2px 8px rgba(0,0,0,0.28)'
                              : '0 2px 8px rgba(0,0,0,0.075)',
                        }}
                        className={[
                          'w-full h-full rounded-[var(--radius-card-outer)] overflow-hidden bg-[var(--bg-subtle)] relative',
                          isSwapTarget
                            ? 'ring-2 ring-dashed ring-[var(--accent)]'
                            : selected
                              ? 'ring-2 ring-[var(--accent)]'
                              : 'ring-1 ring-[var(--border-hairline)]',
                        ].join(' ')}
                      >
                        <div className="w-full h-full overflow-hidden" style={{ transform: mediaFlipTransform }}>
                          <BoardAssetMedia
                            assetId={refKind.assetID}
                            asset={asset}
                            libraryBootstrapped={libraryBootstrapped}
                            weight={refKind.weight}
                            autoplayLoop={refKind.autoplayLoop}
                            cropStyle={cropStyle}
                            onRemoveMissing={() => removeBoardNodesWithFeedback([node.id])}
                          />
                        </div>

                        {asset?.isTrashed && (
                          <div className="pointer-events-none absolute left-1.5 bottom-1.5 px-1.5 py-0.5 rounded-[var(--radius-card-inner)] bg-black/62 text-white text-[9.5px] font-medium">
                            已移入回收站
                          </div>
                        )}

                        {/* Restrained Hover Quick Controls (macOS BoardAssetNodeView parity) */}
                        <div
                          className={[
                            'absolute inset-0 pointer-events-none flex flex-col justify-between p-1.5 transition-opacity duration-150',
                            isSwapTarget ? 'opacity-100' : 'opacity-0 group-hover:opacity-100',
                          ].join(' ')}
                        >
                          <div className="flex items-center justify-between gap-1">
                            {!isMissingAsset && (refKind.weight >= 2 || isEditorial) && (
                              <button
                                type="button"
                                onMouseDown={(e) => e.stopPropagation()}
                                onClick={(e) => {
                                  e.stopPropagation();
                                  mutateActiveBoard((doc) => ({
                                    ...doc,
                                    nodes: doc.nodes.map((n) =>
                                      n.id === node.id && 'assetRef' in n.kind
                                        ? {
                                            ...n,
                                            kind: {
                                              assetRef: {
                                                ...n.kind.assetRef,
                                                weight: n.kind.assetRef.weight >= 2 ? 1 : 2,
                                              },
                                            },
                                          }
                                        : n,
                                    ),
                                  }));
                                }}
                                className={[
                                  'pointer-events-auto charkle-pressable px-1.5 py-0.5 rounded-[var(--radius-card-inner)] text-white text-[10px] font-semibold inline-flex items-center gap-1 cursor-pointer',
                                  refKind.weight >= 2 ? 'bg-[var(--accent)]' : 'bg-black/60',
                                ].join(' ')}
                                title="切换 2× 跨列主图权重"
                              >
                                <Star size={9.5} className={refKind.weight >= 2 ? 'fill-current' : ''} />
                                <span>{refKind.weight >= 2 ? '主图 2×' : '设为主图'}</span>
                              </button>
                            )}
                            <span className="flex-1" />
                            <button
                              type="button"
                              onMouseDown={(e) => e.stopPropagation()}
                              onClick={(e) => {
                                e.stopPropagation();
                                const next = swappingNodeId === node.id ? null : node.id;
                                setSwappingNodeId(next);
                                if (next) setInspectorOpen(true);
                              }}
                              className={[
                                'pointer-events-auto charkle-pressable px-1.5 py-0.5 rounded-[var(--radius-card-inner)] text-white text-[10px] font-semibold inline-flex items-center gap-1 cursor-pointer',
                                isSwapTarget ? 'bg-[var(--accent)]' : 'bg-black/60',
                              ].join(' ')}
                              title="打开右侧候选池原地替换这张图"
                            >
                              <ArrowLeftRight size={9.5} />
                              <span>换一张</span>
                            </button>
                          </div>

                          <div className="flex items-center justify-between gap-1">
                            <div className="flex items-center gap-1">
                              {node.isLocked && (
                                <span className="h-5 w-5 rounded-full bg-black/55 text-white inline-flex items-center justify-center">
                                  <Lock size={9.5} />
                                </span>
                              )}
                              {hasCrop && (
                                <button
                                  type="button"
                                  onMouseDown={(e) => e.stopPropagation()}
                                  onClick={(e) => {
                                    e.stopPropagation();
                                    mutateActiveBoard((doc) => ({
                                      ...doc,
                                      nodes: doc.nodes.map((n) =>
                                        n.id === node.id && 'assetRef' in n.kind
                                          ? { ...n, kind: { assetRef: { ...n.kind.assetRef, crop: null } } }
                                          : n,
                                      ),
                                    }));
                                  }}
                                  className="pointer-events-auto charkle-pressable px-1.5 py-0.5 rounded-[var(--radius-card-inner)] bg-black/60 text-white text-[9.5px] font-semibold cursor-pointer"
                                  title="点击还原完整画面"
                                >
                                  局部取景 · 还原
                                </button>
                              )}
                              {isPlainWebBookmarkAsset(asset) && asset.sourceDomain && !hasCrop && (
                                <span className="px-1.5 py-0.5 rounded-[var(--radius-card-inner)] bg-black/55 text-white text-[9.5px] font-medium truncate max-w-[140px]">
                                  {asset.sourceDomain}
                                </span>
                              )}
                            </div>

                            {!isMissingAsset && (
                              <button
                                type="button"
                                onMouseDown={(e) => e.stopPropagation()}
                                onClick={(e) => {
                                  e.stopPropagation();
                                  openBoardAsset(refKind.assetID, null);
                                }}
                                className="pointer-events-auto charkle-pressable h-5.5 w-5.5 rounded-[var(--radius-card-inner)] bg-black/55 text-white inline-flex items-center justify-center cursor-pointer"
                                title={
                                  isPlainWebBookmarkAsset(asset)
                                    ? '在默认浏览器中打开 (Space)'
                                    : '快速预览 (Space)'
                                }
                              >
                                {isPlainWebBookmarkAsset(asset) ? (
                                  <ExternalLink size={10.5} />
                                ) : (
                                  <Eye size={10.5} />
                                )}
                              </button>
                            )}
                          </div>
                        </div>
                      </div>
                    );
                  })()}

                  {/* 3. Note (Safe palette lookup + click/drag anywhere; double-click/Enter edits) */}
                  {'note' in node.kind && (() => {
                    const noteData = node.kind.note;
                    const st = getNoteStylePalette(noteData.style);
                    const isEditingNote = editingNoteId === node.id;
                    const handleNoteFieldBlur = (
                      e: React.FocusEvent<HTMLInputElement | HTMLTextAreaElement>,
                    ) => {
                      const nextTarget = e.relatedTarget as HTMLElement | null;
                      if (nextTarget?.closest(`[data-board-node-id="${node.id}"]`)) return;
                      setEditingNoteId((cur) => (cur === node.id ? null : cur));
                    };
                    const handleNoteFieldKeyDown = (
                      e: React.KeyboardEvent<HTMLInputElement | HTMLTextAreaElement>,
                    ) => {
                      if (e.key === 'Escape') {
                        e.preventDefault();
                        e.stopPropagation();
                        e.currentTarget.blur();
                        setEditingNoteId(null);
                      }
                    };
                    return (
                      <div
                        style={{
                          backgroundColor: st.bg,
                          color: st.fg,
                          borderColor: selected ? 'var(--accent)' : st.border,
                          borderWidth: selected ? 2 : 1,
                        }}
                        className="w-full h-full rounded-[var(--radius-card-outer)] border p-3 flex flex-col gap-1.5 shadow-[0_3px_12px_rgba(0,0,0,0.08)]"
                      >
                        <div className="flex items-center gap-1.5">
                          {isEditingNote ? (
                            <input
                              type="text"
                              value={noteData.title ?? ''}
                              placeholder="标题 / 氛围词"
                              onMouseDown={(e) => e.stopPropagation()}
                              onBlur={handleNoteFieldBlur}
                              onKeyDown={handleNoteFieldKeyDown}
                              onChange={(e) => {
                                const val = e.target.value;
                                mutateActiveBoard((doc) => ({
                                  ...doc,
                                  nodes: doc.nodes.map((n) =>
                                    n.id === node.id && 'note' in n.kind
                                      ? { ...n, kind: { note: { ...n.kind.note, title: val || null } } }
                                      : n,
                                  ),
                                }));
                              }}
                              style={{ fontSize: Math.max(13, noteData.fontSize) }}
                              className="bg-transparent font-semibold outline-none flex-1 min-w-0"
                            />
                          ) : (
                            <div
                              style={{ fontSize: Math.max(13, noteData.fontSize) }}
                              className="font-semibold flex-1 min-w-0 truncate select-none"
                            >
                              {noteData.title ? (
                                noteData.title
                              ) : (
                                <span className="opacity-45">标题 / 氛围词</span>
                              )}
                            </div>
                          )}
                          <div
                            className={[
                              'flex items-center gap-1 shrink-0 transition-opacity duration-150',
                              selected ? 'opacity-100' : 'opacity-0 group-hover:opacity-100',
                            ].join(' ')}
                          >
                            {(Object.keys(NOTE_STYLE_PALETTE) as NoteStyle[]).map((sKey) => (
                              <button
                                key={sKey}
                                type="button"
                                title={NOTE_STYLE_PALETTE[sKey].label}
                                onMouseDown={(e) => e.stopPropagation()}
                                onClick={(e) => {
                                  e.stopPropagation();
                                  mutateActiveBoard((doc) => ({
                                    ...doc,
                                    nodes: doc.nodes.map((n) =>
                                      n.id === node.id && 'note' in n.kind
                                        ? { ...n, kind: { note: { ...n.kind.note, style: sKey } } }
                                        : n,
                                    ),
                                  }));
                                }}
                                style={{ backgroundColor: NOTE_STYLE_PALETTE[sKey].bg }}
                                className={[
                                  'h-2.5 w-2.5 rounded-full border border-black/25 cursor-pointer',
                                  noteData.style === sKey ? 'ring-1.5 ring-[var(--accent)]' : '',
                                ].join(' ')}
                              />
                            ))}
                          </div>
                        </div>
                        <div
                          className="h-px w-full opacity-10"
                          style={{ backgroundColor: st.fg }}
                        />
                        {isEditingNote ? (
                          <textarea
                            autoFocus
                            value={noteData.text}
                            onMouseDown={(e) => e.stopPropagation()}
                            onBlur={handleNoteFieldBlur}
                            onKeyDown={handleNoteFieldKeyDown}
                            onChange={(e) => {
                              const val = e.target.value;
                              mutateActiveBoard((doc) => ({
                                ...doc,
                                nodes: doc.nodes.map((n) =>
                                  n.id === node.id && 'note' in n.kind
                                    ? { ...n, kind: { note: { ...n.kind.note, text: val } } }
                                    : n,
                                ),
                              }));
                            }}
                            style={{ fontSize: Math.max(11, noteData.fontSize - 1) }}
                            className="flex-1 bg-transparent resize-none outline-none leading-relaxed opacity-90"
                          />
                        ) : (
                          <div
                            style={{ fontSize: Math.max(11, noteData.fontSize - 1) }}
                            className="flex-1 min-h-0 overflow-hidden leading-relaxed opacity-90 whitespace-pre-wrap break-words select-none"
                          >
                            {noteData.text ? (
                              noteData.text
                            ) : (
                              <span className="opacity-45">双击编辑便签…</span>
                            )}
                          </div>
                        )}
                      </div>
                    );
                  })()}

                  {/* 4. PaletteStrip (Full-bleed color bands matching macOS BoardPaletteStripNodeView) */}
                  {'paletteStrip' in node.kind && (() => {
                    const pal = node.kind.paletteStrip;
                    const palColors = Array.isArray(pal.colors) ? pal.colors : [];
                    const swatches =
                      pal.autoSyncWithBoard && safePalette.length > 0
                        ? safePalette
                        : palColors.length > 0
                          ? palColors
                          : [
                              { hex: '#8B95A1', l: 61, a: -2, b: -7, proportion: 0.34 },
                              { hex: '#C8B8A6', l: 75, a: 4, b: 12, proportion: 0.33 },
                              { hex: '#4F5D6B', l: 38, a: -3, b: -8, proportion: 0.33 },
                            ];
                    return (
                      <div
                        className={[
                          'w-full h-full rounded-[var(--radius-card-outer)] overflow-hidden flex items-stretch shadow-[0_3px_12px_rgba(0,0,0,0.08)]',
                          selected
                            ? 'ring-2 ring-[var(--accent)]'
                            : 'ring-1 ring-[var(--border-hairline)]',
                        ].join(' ')}
                      >
                        {swatches.slice(0, 7).map((sw) => {
                          const hex = sw.hex.toUpperCase();
                          const light = isLightHex(hex);
                          return (
                            <div
                              key={hex}
                              role="button"
                              tabIndex={-1}
                              data-swatch-hex={hex}
                              onClick={() => {
                                if (
                                  tool !== 'select' ||
                                  Date.now() - lastNodeDragEndedAtRef.current <= 220 ||
                                  wasRecentPointerDrag()
                                ) {
                                  return;
                                }
                                handleCopyColorHex(hex);
                              }}
                              style={{ backgroundColor: hex }}
                              className="flex-1 flex items-end justify-start p-2 cursor-pointer select-none"
                              title={`单击复制 ${hex}，拖拽可移动色卡条，右键更多操作`}
                            >
                              <span
                                style={{
                                  color: light ? 'rgba(0,0,0,0.76)' : 'rgba(255,255,255,0.88)',
                                }}
                                className="text-[10px] font-semibold charkle-mono select-none"
                              >
                                {hex}
                              </span>
                            </div>
                          );
                        })}
                      </div>
                    );
                  })()}
                </div>
              );
            })}

            {/* 5. World SVG Annotation Layer: Connectors, Pending Port Preview & Ink Strokes */}
            <svg
              aria-hidden="true"
              className="pointer-events-none absolute inset-0 overflow-visible z-[850]"
              width="1"
              height="1"
            >
              {visibleConnectors.map((conn) => {
                const fr = effectiveFramesMap.get(conn.fromNodeID);
                const tr = effectiveFramesMap.get(conn.toNodeID);
                if (!fr || !tr) return null;
                const geom = buildConnectorSvgPath(conn, fr, tr);
                const isSel = selectedConnectorId === conn.id;
                const strokeColor = isSel ? 'var(--accent)' : conn.colorHex || '#5C6672';
                return (
                  <g key={conn.id}>
                    <path
                      d={geom.path}
                      fill="none"
                      stroke={strokeColor}
                      strokeWidth={isSel ? 2.6 : 2.0}
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      strokeDasharray={conn.dashed ? '7 5' : undefined}
                    />
                    <path
                      d={geom.arrowHeadPath}
                      fill="none"
                      stroke={strokeColor}
                      strokeWidth={2.0}
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                    {conn.toNormalizedPoint && (
                      <>
                        <circle
                          cx={geom.end.x}
                          cy={geom.end.y}
                          r={8.5}
                          fill={strokeColor}
                          fillOpacity={0.22}
                        />
                        <circle
                          cx={geom.end.x}
                          cy={geom.end.y}
                          r={3.5}
                          fill={strokeColor}
                          stroke="#ffffff"
                          strokeWidth={1.3}
                        />
                      </>
                    )}
                  </g>
                );
              })}

              {/* Pending port drag dashed Bezier preview (anchor-oriented normal) */}
              {livePortConn && (() => {
                const s = livePortConn.startWorld;
                const e = livePortConn.cursorWorld;
                const dist = Math.max(36, Math.min(180, Math.hypot(e.x - s.x, e.y - s.y) * 0.4));
                let c1x = s.x;
                let c1y = s.y;
                if (livePortConn.fromAnchor === 'top') c1y -= dist;
                else if (livePortConn.fromAnchor === 'bottom') c1y += dist;
                else if (livePortConn.fromAnchor === 'leading') c1x -= dist;
                else if (livePortConn.fromAnchor === 'trailing') c1x += dist;
                else c1x += (e.x >= s.x ? 1 : -1) * dist * 0.5;
                const c2x = e.x - (e.x - s.x) * 0.25;
                const c2y = e.y - (e.y - s.y) * 0.25;
                const d = `M ${s.x} ${s.y} C ${c1x} ${c1y}, ${c2x} ${c2y}, ${e.x} ${e.y}`;
                return (
                  <path
                    d={d}
                    fill="none"
                    stroke="var(--accent)"
                    strokeWidth={2}
                    strokeLinecap="round"
                    strokeDasharray="5 4"
                  />
                );
              })()}

              {/* Smooth Quadratic Ink Strokes */}
              {visibleInkStrokes.map((stroke) => {
                if (!Array.isArray(stroke.points) || stroke.points.length < 2) return null;
                return (
                  <path
                    key={stroke.id}
                    d={buildInkStrokeSvgPath(stroke.points)}
                    fill="none"
                    stroke={stroke.colorHex}
                    strokeWidth={stroke.lineWidth}
                    strokeOpacity={stroke.opacity}
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                );
              })}

              {liveStroke && liveStroke.length >= 2 && (
                <path
                  d={buildInkStrokeSvgPath(liveStroke)}
                  fill="none"
                  stroke={inkColor}
                  strokeWidth={inkWidth}
                  strokeOpacity={0.92}
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              )}
            </svg>
          </div>

          {/* 4. Screen-Space Constant-Size Selection Handles, Side-Edge Pills, Rotation Knob & Connector Ports */}
          {!isEditorial && screenHandleNodes.length > 0 && (
            <div className="pointer-events-none absolute inset-0 z-20 overflow-hidden">
              {screenHandleNodes.map((node) => {
                const worldRect = effectiveFramesMap.get(node.id) ?? node.frame;
                const screenCenter = worldToScreen(
                  { x: worldRect.x + worldRect.width * 0.5, y: worldRect.y + worldRect.height * 0.5 },
                  camera,
                  stageSize,
                );
                const screenW = Math.max(24, worldRect.width * camera.zoom);
                const screenH = Math.max(24, worldRect.height * camera.zoom);
                const rot = effectiveRotation(node);
                const isSelected = selectedNodeIds.includes(node.id);
                const isGroup = 'groupFrame' in node.kind;
                const isResizingThis = liveResize?.nodeId === node.id;
                const isRotatingThis = liveRotate?.nodeId === node.id;

                const ports: Array<{
                  anchor: ConnectorAnchor;
                  offsetX: number;
                  offsetY: number;
                  worldPt: BoardPoint;
                }> = [
                  {
                    anchor: 'top',
                    offsetX: 0,
                    offsetY: -screenH * 0.5,
                    worldPt: { x: worldRect.x + worldRect.width * 0.5, y: worldRect.y },
                  },
                  {
                    anchor: 'bottom',
                    offsetX: 0,
                    offsetY: screenH * 0.5,
                    worldPt: { x: worldRect.x + worldRect.width * 0.5, y: worldRect.y + worldRect.height },
                  },
                  {
                    anchor: 'leading',
                    offsetX: -screenW * 0.5,
                    offsetY: 0,
                    worldPt: { x: worldRect.x, y: worldRect.y + worldRect.height * 0.5 },
                  },
                  {
                    anchor: 'trailing',
                    offsetX: screenW * 0.5,
                    offsetY: 0,
                    worldPt: { x: worldRect.x + worldRect.width, y: worldRect.y + worldRect.height * 0.5 },
                  },
                ];

                return (
                  <div
                    key={node.id}
                    style={{
                      position: 'absolute',
                      left: screenCenter.x,
                      top: screenCenter.y,
                      width: 0,
                      height: 0,
                      transform: `rotate(${rot}deg)`,
                    }}
                  >
                    {/* Connector Edge Ports (shown on hover, selection, or connector tool) */}
                    {ports.map((port) => (
                      <div
                        key={port.anchor}
                        role="button"
                        aria-label={`连线端口 ${port.anchor}`}
                        title="拖拽连线至其他卡片"
                        onPointerDown={(e) => startPortDrag(e, node, port.anchor, port.worldPt)}
                        style={{
                          position: 'absolute',
                          left: port.offsetX - 9,
                          top: port.offsetY - 9,
                          width: 18,
                          height: 18,
                        }}
                        className="pointer-events-auto flex items-center justify-center cursor-crosshair"
                      >
                        <span className="h-2.5 w-2.5 rounded-full bg-[var(--accent)] border-[1.5px] border-white shadow-xs" />
                      </div>
                    ))}

                    {/* 4-Corner Resize Handles + GroupFrame Side-Edge Pills + Rotation Handle */}
                    {isSelected && !node.isLocked && tool === 'select' && (
                      <>
                        {/* GroupFrame Left & Right Side Edge Resize Pills */}
                        {isGroup &&
                          ([-1, 1] as const).map((side) => {
                            const isActiveEdge = isResizingThis && liveResize?.sideEdge === side;
                            return (
                              <div
                                key={side}
                                role="presentation"
                                data-testid={`group-side-handle-${side < 0 ? 'left' : 'right'}`}
                                title="左右拖拽实时缩放并自动重排框内素材"
                                onPointerDown={(e) => startResizeHandle(e, node, null, side)}
                                style={{
                                  position: 'absolute',
                                  left: side * screenW * 0.5 - 12,
                                  top: -26,
                                  width: 24,
                                  height: 52,
                                }}
                                className="pointer-events-auto flex items-center justify-center cursor-ew-resize"
                              >
                                <span
                                  className={[
                                    'w-[5px] h-[34px] rounded-full border-[1.5px] border-[var(--accent)] shadow-sm',
                                    isActiveEdge ? 'bg-[var(--accent)]' : 'bg-white',
                                  ].join(' ')}
                                />
                              </div>
                            );
                          })}

                        {/* 4 Corner Resize Handles */}
                        {RESIZE_CORNERS.map((corner) => {
                          const isActiveCorner =
                            isResizingThis &&
                            liveResize?.sideEdge === 0 &&
                            liveResize?.corner === corner.id;
                          return (
                            <div
                              key={corner.id}
                              role="presentation"
                              data-testid={`resize-handle-${corner.id}`}
                              title={
                                'assetRef' in node.kind
                                  ? '拖拽调整尺寸（按住 Shift 自由拉伸）'
                                  : '拖拽自由调整尺寸（按住 Shift 锁定比例）'
                              }
                              onPointerDown={(e) => startResizeHandle(e, node, corner.id, 0)}
                              style={{
                                position: 'absolute',
                                left: corner.signX * screenW * 0.5 - 12,
                                top: corner.signY * screenH * 0.5 - 12,
                                width: 24,
                                height: 24,
                                cursor: corner.cursor,
                              }}
                              className="pointer-events-auto flex items-center justify-center"
                            >
                              <span
                                className={[
                                  'rounded-full border-2 border-[var(--accent)] shadow-xs',
                                  isActiveCorner
                                    ? 'h-3 w-3 bg-[var(--accent)]'
                                    : 'h-2.5 w-2.5 bg-white',
                                ].join(' ')}
                              />
                              {isActiveCorner && liveResize && (
                                <span
                                  style={{ transform: `rotate(${-rot}deg)` }}
                                  className="pointer-events-none absolute top-6 whitespace-nowrap px-1.5 py-0.5 rounded-full bg-black/78 text-white text-[10px] font-semibold charkle-mono charkle-tabular"
                                >
                                  {Math.round(liveResize.liveRect.width)} ×{' '}
                                  {Math.round(liveResize.liveRect.height)}
                                </span>
                              )}
                            </div>
                          );
                        })}

                        {/* Top-Center Interactive Rotation Handle */}
                        <div
                          style={{
                            position: 'absolute',
                            left: -12,
                            top: -(screenH * 0.5 + 36),
                            width: 24,
                            height: 36,
                          }}
                          className="flex flex-col items-center"
                        >
                          <div
                            role="button"
                            data-testid="rotation-handle"
                            aria-label="自由旋转节点"
                            title="拖拽自由旋转（按住 Shift 以 15° 吸附，双击归零）"
                            onPointerDown={(e) => startRotationHandle(e, node, screenCenter)}
                            onDoubleClick={(e) => {
                              e.stopPropagation();
                              resetNodesRotation([node.id]);
                            }}
                            className={[
                              'pointer-events-auto charkle-pressable relative h-[22px] w-[22px] rounded-full border-[1.5px] border-[var(--accent)] shadow-sm flex items-center justify-center cursor-grab active:cursor-grabbing',
                              isRotatingThis
                                ? 'bg-[var(--accent)] text-white'
                                : 'bg-white text-[var(--accent)]',
                            ].join(' ')}
                          >
                            <RotateCw size={10} strokeWidth={2.3} />
                            {isRotatingThis && (
                              <span
                                style={{ transform: `rotate(${-rot}deg)` }}
                                className="pointer-events-none absolute -top-7 whitespace-nowrap px-2 py-0.5 rounded-full bg-black/78 text-white text-[10.5px] font-semibold charkle-mono charkle-tabular"
                              >
                                {Math.round(rot)}°
                              </span>
                            )}
                          </div>
                          <div className="w-[1.5px] h-[14px] bg-[var(--accent)]/75 pointer-events-none" />
                        </div>
                      </>
                    )}
                  </div>
                );
              })}
            </div>
          )}

          {/* 5. Interactive Connector Midpoint Labels */}
          {!isEditorial && !cameraAnimated && visibleConnectors.length > 0 && (
            <div className="pointer-events-none absolute inset-0 z-20 overflow-hidden">
              {visibleConnectors.map((conn) => {
                const fr = effectiveFramesMap.get(conn.fromNodeID);
                const tr = effectiveFramesMap.get(conn.toNodeID);
                if (!fr || !tr) return null;
                const geom = buildConnectorSvgPath(conn, fr, tr);
                const midScreen = worldToScreen(geom.mid, camera, stageSize);
                const isSel = selectedConnectorId === conn.id;
                const hasLabel = Boolean(conn.label && conn.label.trim());
                if (!hasLabel && !isSel && tool !== 'connector') return null;

                return (
                  <button
                    key={conn.id}
                    type="button"
                    data-stage-floating-ui="true"
                    onClick={(e) => {
                      e.stopPropagation();
                      setSelectedConnectorId(conn.id);
                      const rect = stageRef.current?.getBoundingClientRect();
                      setEditingConnector({
                        id: conn.id,
                        x: (rect?.left ?? 0) + midScreen.x,
                        y: (rect?.top ?? 0) + midScreen.y,
                        draft: conn.label ?? '',
                      });
                    }}
                    style={{
                      position: 'absolute',
                      left: midScreen.x,
                      top: midScreen.y,
                      transform: 'translate(-50%, -50%)',
                    }}
                    className={
                      hasLabel
                        ? [
                            'pointer-events-auto px-2 py-0.5 rounded-full bg-[var(--bg-elevated)] text-[11px] font-medium text-[var(--text-primary)] border shadow-xs cursor-pointer',
                            isSel ? 'border-[var(--accent)]' : 'border-[var(--border-hairline)]',
                          ].join(' ')
                        : 'pointer-events-auto h-4 w-4 rounded-full bg-[var(--bg-elevated)] border border-[var(--accent)]/60 text-[var(--text-secondary)] inline-flex items-center justify-center cursor-pointer'
                    }
                    title="点击编辑连线标签"
                  >
                    {hasLabel ? conn.label : <Tag size={8} />}
                  </button>
                );
              })}
            </div>
          )}

          {/* 6. Screen-Space Marquee Box-Select Overlay */}
          {liveMarquee && liveMarquee.started && (
            <div
              aria-hidden="true"
              className="pointer-events-none absolute rounded-[4px] border border-[var(--accent)]/70 bg-[var(--accent-soft)] z-25"
              style={{
                left: Math.min(liveMarquee.startScreen.x, liveMarquee.curScreen.x),
                top: Math.min(liveMarquee.startScreen.y, liveMarquee.curScreen.y),
                width: Math.abs(liveMarquee.curScreen.x - liveMarquee.startScreen.x),
                height: Math.abs(liveMarquee.curScreen.y - liveMarquee.startScreen.y),
              }}
            />
          )}

          {/* 7. Top Floating Liquid Glass Board Palette Header Strip (macOS BoardPaletteHeaderStrip 1:1) */}
          {showTopPaletteStrip && safePalette.length > 0 && (
            <div
              style={{
                paddingLeft: 14,
                paddingRight: dockLayout.paletteTrailingClearance ? 96 : 14,
              }}
              className="pointer-events-none absolute top-3.5 inset-x-0 z-30 flex justify-center"
            >
              <div
                data-testid="board-palette-header-strip"
                data-stage-floating-ui="true"
                className="pointer-events-auto charkle-glass charkle-reveal-top rounded-full px-3 py-1.5 flex items-center gap-1.5 w-fit max-w-full overflow-x-auto charkle-scroll-hidden"
              >
                <span className="text-[11px] font-medium text-[var(--text-secondary)] pr-0.5 shrink-0 whitespace-nowrap">
                  板内色卡
                </span>
                {safePalette.slice(0, 7).map((swatch) => {
                  const hex = swatch.hex.toUpperCase();
                  const light = isLightHex(hex);
                  const isCopied = copiedPaletteHex === hex;
                  return (
                    <button
                      key={hex}
                      type="button"
                      onClick={() => handleCopyColorHex(hex)}
                      onContextMenu={(e) => {
                        e.preventDefault();
                        handleSearchColorHex(hex);
                      }}
                      title={`点击复制 ${hex}，右键以此色检索素材库`}
                      className="charkle-pressable inline-flex items-center gap-1.5 px-2 py-1 rounded-[var(--radius-chip)] bg-[var(--bg-elevated)]/88 border border-[var(--border-hairline)] shrink-0 cursor-pointer"
                    >
                      <span
                        style={{
                          backgroundColor: hex,
                          borderColor: light ? 'rgba(0,0,0,0.14)' : 'rgba(255,255,255,0.22)',
                        }}
                        className="h-3.5 w-3.5 rounded-[4px] border shrink-0"
                      />
                      <span className="text-[10.5px] font-medium charkle-mono text-[var(--text-primary)]/85">
                        {isCopied ? '已复制' : hex}
                      </span>
                    </button>
                  );
                })}
              </div>
            </div>
          )}

          {/* 8. Unified 3-Tier Responsive Bottom HUD (Transform Pill + Contextual Tool Sub-Pill + Tool Dock + Zoom Controls) */}
          {(() => {
            const penOptionsContent = (
              <div className="flex items-center gap-1 shrink-0">
                {CALM_INK_SWATCHES.map((sw) => (
                  <button
                    key={sw.hex}
                    type="button"
                    title={sw.name}
                    onClick={() => setInkColor(sw.hex)}
                    style={{ backgroundColor: sw.hex }}
                    className={[
                      'h-3.5 w-3.5 rounded-full border border-white/45 cursor-pointer shrink-0',
                      inkColor === sw.hex ? 'ring-2 ring-[var(--accent)]' : '',
                    ].join(' ')}
                  />
                ))}
                <div className="ml-1 flex items-center gap-0.5 bg-[var(--bg-subtle)] rounded-[6px] p-0.5 shrink-0">
                  {[
                    { label: '细', val: 2.0 },
                    { label: '中', val: 3.5 },
                    { label: '粗', val: 6.5 },
                  ].map((w) => (
                    <button
                      key={w.label}
                      type="button"
                      onClick={() => setInkWidth(w.val)}
                      className={[
                        'px-1.5 h-5 rounded-[4px] text-[10.5px] font-medium cursor-pointer shrink-0 whitespace-nowrap',
                        inkWidth === w.val
                          ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-2xs'
                          : 'text-[var(--text-secondary)]',
                      ].join(' ')}
                    >
                      {w.label}
                    </button>
                  ))}
                </div>
              </div>
            );

            const connectorOptionsContent = (
              <div className="flex items-center gap-0.5 shrink-0">
                {(['curved', 'elbow', 'straight'] as ConnectorStyle[]).map((st) => (
                  <button
                    key={st}
                    type="button"
                    onClick={() => setConnectorStyle(st)}
                    className={[
                      'px-1.5 h-6 rounded-[6px] text-[11px] font-medium cursor-pointer shrink-0 whitespace-nowrap',
                      connectorStyle === st
                        ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                        : 'text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)]',
                    ].join(' ')}
                  >
                    {st === 'curved' ? '曲线' : st === 'elbow' ? '折线' : '直线'}
                  </button>
                ))}
                <button
                  type="button"
                  onClick={() => setConnectorDashed((v) => !v)}
                  className={[
                    'px-1.5 h-6 rounded-[6px] text-[11px] font-medium cursor-pointer shrink-0 whitespace-nowrap',
                    connectorDashed
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                      : 'text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)]',
                  ].join(' ')}
                >
                  虚线
                </button>
              </div>
            );

            const toolBtnSize = dockLayout.compactButtons ? 'h-7 w-7' : 'h-8 w-8';
            const toolIconSize = dockLayout.compactButtons ? 13.5 : 15;
            const insertBtnSize = dockLayout.compactButtons ? 'h-7 px-1.5' : 'h-8 px-2';
            const insertIconSize = dockLayout.compactButtons ? 13 : 14;

            const toolDockElement = (
              <div
                data-testid="moodboard-tool-dock"
                className={[
                  'pointer-events-auto charkle-glass flex items-center text-[12px] shrink-0',
                  dockLayout.compactButtons
                    ? 'rounded-[16px] px-1.5 py-1 gap-0.5'
                    : 'rounded-[var(--radius-dock-outer)] px-2 py-1.5 gap-1',
                ].join(' ')}
              >
                <button
                  type="button"
                  onClick={() => setTool('select')}
                  title="选择 (V)"
                  aria-label="选择工具"
                  className={[
                    'charkle-pressable rounded-[var(--radius-dock-inner)] inline-flex items-center justify-center cursor-pointer shrink-0',
                    toolBtnSize,
                    tool === 'select'
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                      : 'text-[var(--text-primary)]/85 hover:bg-[var(--bg-subtle)]',
                  ].join(' ')}
                >
                  <MousePointer2 size={toolIconSize} />
                </button>

                <button
                  type="button"
                  onClick={() => {
                    if (isEditorial) switchBoardMode('freeform', stageSize.width, assetsById);
                    setTool('hand');
                  }}
                  title="抓手 (H · 空格+拖拽)"
                  aria-label="平移工具"
                  className={[
                    'charkle-pressable rounded-[var(--radius-dock-inner)] inline-flex items-center justify-center cursor-pointer shrink-0',
                    toolBtnSize,
                    tool === 'hand'
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                      : 'text-[var(--text-primary)]/85 hover:bg-[var(--bg-subtle)]',
                  ].join(' ')}
                >
                  <Hand size={toolIconSize} />
                </button>

                <button
                  type="button"
                  onClick={() => setTool(tool === 'connector' ? 'select' : 'connector')}
                  title="连线 (C)"
                  aria-label="连线工具"
                  className={[
                    'charkle-pressable rounded-[var(--radius-dock-inner)] inline-flex items-center justify-center cursor-pointer shrink-0',
                    toolBtnSize,
                    tool === 'connector'
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                      : 'text-[var(--text-primary)]/85 hover:bg-[var(--bg-subtle)]',
                  ].join(' ')}
                >
                  <ArrowUpRight size={toolIconSize} />
                </button>

                <button
                  type="button"
                  onClick={() => {
                    if (isEditorial) switchBoardMode('freeform', stageSize.width, assetsById);
                    setTool(tool === 'ink' ? 'select' : 'ink');
                  }}
                  title="手绘 (P)"
                  aria-label="画笔工具"
                  className={[
                    'charkle-pressable rounded-[var(--radius-dock-inner)] inline-flex items-center justify-center cursor-pointer shrink-0',
                    toolBtnSize,
                    tool === 'ink'
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                      : 'text-[var(--text-primary)]/85 hover:bg-[var(--bg-subtle)]',
                  ].join(' ')}
                >
                  <PenTool size={toolIconSize} />
                </button>

                <button
                  type="button"
                  onClick={() => {
                    if (isEditorial) switchBoardMode('freeform', stageSize.width, assetsById);
                    setTool(tool === 'eraser' ? 'select' : 'eraser');
                  }}
                  title="橡皮 (E · 擦除连线与手绘)"
                  aria-label="橡皮工具"
                  className={[
                    'charkle-pressable rounded-[var(--radius-dock-inner)] inline-flex items-center justify-center cursor-pointer shrink-0',
                    toolBtnSize,
                    tool === 'eraser'
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                      : 'text-[var(--text-primary)]/85 hover:bg-[var(--bg-subtle)]',
                  ].join(' ')}
                >
                  <Eraser size={toolIconSize} />
                </button>

                {/* Inline contextual options strictly on >= 960px wide canvas */}
                {dockLayout.inlineToolOptions && tool === 'ink' && (
                  <>
                    <div className="h-4.5 w-px bg-[var(--border-hairline)] mx-0.5 shrink-0" />
                    {penOptionsContent}
                  </>
                )}
                {dockLayout.inlineToolOptions && tool === 'connector' && (
                  <>
                    <div className="h-4.5 w-px bg-[var(--border-hairline)] mx-0.5 shrink-0" />
                    {connectorOptionsContent}
                  </>
                )}

                <div className="h-4.5 w-px bg-[var(--border-hairline)] mx-0.5 shrink-0" />

                {/* Insert Nodes + Tidy */}
                <button
                  type="button"
                  onClick={() => addNoteNode('warm', getSpawnWorldCenter())}
                  title="添加便签卡片"
                  aria-label="添加便签"
                  className={[
                    'charkle-pressable rounded-[var(--radius-dock-inner)] inline-flex items-center justify-center gap-1 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0 whitespace-nowrap',
                    insertBtnSize,
                  ].join(' ')}
                >
                  <StickyNote size={insertIconSize} />
                  {dockLayout.showInsertLabels && <span>便签</span>}
                </button>

                <button
                  type="button"
                  onClick={() => addGroupFrameNode('sand', getSpawnWorldCenter())}
                  title="添加区域分组框"
                  aria-label="添加分组框"
                  className={[
                    'charkle-pressable rounded-[var(--radius-dock-inner)] inline-flex items-center justify-center gap-1 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0 whitespace-nowrap',
                    insertBtnSize,
                  ].join(' ')}
                >
                  <SquareDashed size={insertIconSize} />
                  {dockLayout.showInsertLabels && <span>分组</span>}
                </button>

                <button
                  type="button"
                  onClick={() => addPaletteStripNode(getSpawnWorldCenter())}
                  title="添加全板色卡条"
                  aria-label="添加色卡条"
                  className={[
                    'charkle-pressable rounded-[var(--radius-dock-inner)] inline-flex items-center justify-center gap-1 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0 whitespace-nowrap',
                    insertBtnSize,
                  ].join(' ')}
                >
                  <Palette size={insertIconSize} />
                  {dockLayout.showInsertLabels && <span>色卡</span>}
                </button>

                {!isEditorial && (
                  <button
                    type="button"
                    onClick={() => tidyActiveBoard(assetsById)}
                    title="重新整齐排版"
                    aria-label="整理对齐"
                    className={[
                      'charkle-pressable rounded-[var(--radius-dock-inner)] inline-flex items-center justify-center text-[var(--text-primary)]/85 hover:bg-[var(--bg-subtle)] cursor-pointer shrink-0',
                      toolBtnSize,
                    ].join(' ')}
                  >
                    <Wand2 size={insertIconSize} />
                  </button>
                )}
              </div>
            );

            const zoomCompact = dockLayout.tier !== 'wide';
            const zoomBtnSize = zoomCompact ? 'h-5.5 w-5.5' : 'h-6 w-6';
            const zoomPillElement = !isEditorial ? (
              <div
                data-testid="freeform-zoom-controls"
                data-stage-floating-ui="true"
                className={[
                  'pointer-events-auto charkle-glass rounded-full flex items-center select-none shrink-0',
                  zoomCompact ? 'px-1.5 py-0.5 gap-0' : 'px-2 py-1 gap-0.5',
                ].join(' ')}
              >
                <button
                  type="button"
                  aria-label="缩小画布"
                  title="缩小画布"
                  onClick={() =>
                    applyZoomAtScreenPoint(0.82, stageSize.width * 0.5, stageSize.height * 0.5, true)
                  }
                  className={[
                    'charkle-pressable rounded-full hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] inline-flex items-center justify-center cursor-pointer',
                    zoomBtnSize,
                  ].join(' ')}
                >
                  <Minus size={zoomCompact ? 10.5 : 11.5} />
                </button>
                <button
                  type="button"
                  title="重置为 100%"
                  onClick={() => triggerSmoothCameraUpdate((prev) => ({ ...prev, zoom: 1 }))}
                  className={[
                    'charkle-pressable px-1 rounded-full hover:bg-[var(--bg-subtle)] font-semibold charkle-mono charkle-tabular text-[var(--text-primary)] cursor-pointer',
                    zoomCompact ? 'min-w-[36px] h-5.5 text-[10.5px]' : 'min-w-[42px] h-6 text-[11px]',
                  ].join(' ')}
                >
                  {Math.round(camera.zoom * 100)}%
                </button>
                <button
                  type="button"
                  aria-label="放大画布"
                  title="放大画布"
                  onClick={() =>
                    applyZoomAtScreenPoint(1.22, stageSize.width * 0.5, stageSize.height * 0.5, true)
                  }
                  className={[
                    'charkle-pressable rounded-full hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] inline-flex items-center justify-center cursor-pointer',
                    zoomBtnSize,
                  ].join(' ')}
                >
                  <Plus size={zoomCompact ? 10.5 : 11.5} />
                </button>
                <div className="h-3.5 w-px bg-[var(--border-hairline)] mx-1" />
                <button
                  type="button"
                  aria-label="适应画布"
                  title="适应画布 (Fit Board)"
                  onClick={fitBoardToScreen}
                  className={[
                    'charkle-pressable rounded-full hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] inline-flex items-center justify-center cursor-pointer',
                    zoomBtnSize,
                  ].join(' ')}
                >
                  <Maximize2 size={zoomCompact ? 10.5 : 11.5} />
                </button>
              </div>
            ) : null;

            return (
              <div
                data-testid="moodboard-bottom-hud"
                data-dock-tier={dockLayout.tier}
                data-stage-floating-ui="true"
                className="pointer-events-none absolute inset-x-0 bottom-0 z-30 px-3.5 pb-4 flex flex-col items-center gap-2"
              >
                {/* Floating Selected Transform Pill (stacked cleanly above Tool Dock) */}
                {showTransformPill && (() => {
                  const selectedNodesList = safeNodes.filter((n) =>
                    selectedNodeIds.includes(n.id),
                  );
                  const allSelectedIds = selectedNodesList.map((n) => n.id);
                  if (allSelectedIds.length === 0) return null;
                  const targetIds = selectedUnlockedNodes.map((n) => n.id);
                  const allSelectedLocked = selectedNodesList.every((n) => n.isLocked);
                  const singleAngle =
                    selectedUnlockedNodes.length === 1
                      ? effectiveRotation(selectedUnlockedNodes[0])
                      : 0;
                  const anyRotated =
                    Math.abs(singleAngle) > 0.1 ||
                    selectedUnlockedNodes.some((n) => Math.abs(n.rotationDegrees) > 0.1);
                  const anyFlippedH = selectedUnlockedNodes.some((n) => n.flipHorizontal);
                  const anyFlippedV = selectedUnlockedNodes.some((n) => n.flipVertical);

                  return (
                    <div
                      data-testid="selected-transform-pill"
                      className="pointer-events-auto charkle-glass charkle-reveal-bottom rounded-full px-2 py-1 flex items-center gap-1 text-[11.5px] max-w-full overflow-x-auto charkle-scroll-hidden"
                    >
                      {allSelectedIds.length > 1 && (
                        <>
                          <span className="px-1.5 text-[11px] font-semibold charkle-tabular text-[var(--text-secondary)] shrink-0 whitespace-nowrap">
                            已选 {allSelectedIds.length} 项
                          </span>
                          <div className="h-4 w-px bg-[var(--border-hairline)] shrink-0" />
                        </>
                      )}

                      {targetIds.length > 0 && (
                        <>
                          <button
                            type="button"
                            title="逆时针 90° (Shift+R)"
                            aria-label="逆时针旋转 90°"
                            onClick={() => rotateNodes(targetIds, -90)}
                            className="charkle-pressable h-6.5 w-7 rounded-[var(--radius-chip)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] inline-flex items-center justify-center cursor-pointer shrink-0"
                          >
                            <RotateCcw size={12.5} />
                          </button>
                          <button
                            type="button"
                            title="顺时针 90° (R)"
                            aria-label="顺时针旋转 90°"
                            onClick={() => rotateNodes(targetIds, 90)}
                            className="charkle-pressable h-6.5 w-7 rounded-[var(--radius-chip)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] inline-flex items-center justify-center cursor-pointer shrink-0"
                          >
                            <RotateCw size={12.5} />
                          </button>
                          {anyRotated && (
                            <button
                              type="button"
                              title="点击重置旋转角度至 0°"
                              onClick={() => resetNodesRotation(targetIds)}
                              className="charkle-pressable h-6.5 px-2 rounded-[var(--radius-chip)] bg-[var(--accent-soft)] text-[var(--accent)] inline-flex items-center gap-1 text-[11px] font-semibold charkle-mono charkle-tabular cursor-pointer shrink-0"
                            >
                              <span>
                                {selectedUnlockedNodes.length === 1
                                  ? `${Math.round(singleAngle)}°`
                                  : '重置角度'}
                              </span>
                              <Undo2 size={9.5} />
                            </button>
                          )}

                          <div className="h-4 w-px bg-[var(--border-hairline)] mx-0.5 shrink-0" />

                          <button
                            type="button"
                            title="水平翻转 (Shift+H)"
                            aria-label="水平翻转"
                            onClick={() => flipNodes(targetIds, true)}
                            className={[
                              'charkle-pressable h-6.5 w-7 rounded-[var(--radius-chip)] inline-flex items-center justify-center cursor-pointer shrink-0',
                              anyFlippedH
                                ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                                : 'hover:bg-[var(--bg-subtle)] text-[var(--text-primary)]',
                            ].join(' ')}
                          >
                            <FlipHorizontal2 size={12.5} />
                          </button>
                          <button
                            type="button"
                            title="上下翻转 (Shift+V)"
                            aria-label="上下翻转"
                            onClick={() => flipNodes(targetIds, false)}
                            className={[
                              'charkle-pressable h-6.5 w-7 rounded-[var(--radius-chip)] inline-flex items-center justify-center cursor-pointer shrink-0',
                              anyFlippedV
                                ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                                : 'hover:bg-[var(--bg-subtle)] text-[var(--text-primary)]',
                            ].join(' ')}
                          >
                            <FlipVertical2 size={12.5} />
                          </button>
                        </>
                      )}

                      {selectedSingleNode && 'assetRef' in selectedSingleNode.kind && (
                        <>
                          {targetIds.length > 0 && (
                            <div className="h-4 w-px bg-[var(--border-hairline)] mx-0.5 shrink-0" />
                          )}
                          <button
                            ref={cropBtnRef}
                            type="button"
                            onClick={() => setCropOpen((v) => !v)}
                            title="非破坏性局部裁切"
                            className="charkle-pressable h-6.5 px-2 rounded-[var(--radius-chip)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] inline-flex items-center gap-1 cursor-pointer shrink-0 whitespace-nowrap"
                          >
                            <Crop size={12} />
                            <span>裁切</span>
                          </button>
                          <button
                            type="button"
                            onClick={() =>
                              void revealAssetInLibrary(
                                'assetRef' in selectedSingleNode.kind
                                  ? selectedSingleNode.kind.assetRef.assetID
                                  : '',
                              )
                            }
                            title="在素材库中定位此素材"
                            className="charkle-pressable h-6.5 px-2 rounded-[var(--radius-chip)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] inline-flex items-center gap-1 cursor-pointer shrink-0 whitespace-nowrap"
                          >
                            <Compass size={12} />
                            <span>定位</span>
                          </button>
                        </>
                      )}

                      {(targetIds.length > 0 ||
                        (selectedSingleNode && 'assetRef' in selectedSingleNode.kind)) && (
                        <div className="h-4 w-px bg-[var(--border-hairline)] mx-0.5 shrink-0" />
                      )}
                      <button
                        type="button"
                        title={
                          allSelectedLocked
                            ? allSelectedIds.length > 1
                              ? `解锁已选 ${allSelectedIds.length} 项位置`
                              : '解锁位置'
                            : allSelectedIds.length > 1
                              ? `锁定已选 ${allSelectedIds.length} 项位置`
                              : '锁定位置'
                        }
                        aria-label={allSelectedLocked ? '解锁位置' : '锁定位置'}
                        onClick={() => {
                          const idSet = new Set(allSelectedIds);
                          mutateActiveBoard(
                            (doc) => ({
                              ...doc,
                              nodes: doc.nodes.map((n) =>
                                idSet.has(n.id) ? { ...n, isLocked: !allSelectedLocked } : n,
                              ),
                            }),
                            { recordUndo: true, immediateSave: true },
                          );
                        }}
                        className="charkle-pressable h-6.5 w-6.5 rounded-[var(--radius-chip)] hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] inline-flex items-center justify-center cursor-pointer shrink-0"
                      >
                        {allSelectedLocked ? <Unlock size={12} /> : <Lock size={12} />}
                      </button>
                      <button
                        type="button"
                        title={
                          allSelectedIds.length > 1
                            ? `从画布移除已选 ${allSelectedIds.length} 项 (Delete)`
                            : '从画布移除 (Delete)'
                        }
                        aria-label="删除选中节点"
                        onClick={() => removeBoardNodesWithFeedback(allSelectedIds)}
                        className={[
                          'charkle-pressable h-6.5 rounded-[var(--radius-chip)] hover:bg-[var(--danger-soft)] text-[var(--danger)] inline-flex items-center justify-center gap-1 cursor-pointer shrink-0 whitespace-nowrap',
                          allSelectedIds.length > 1 ? 'px-2 text-[11px] font-medium' : 'w-6.5',
                        ].join(' ')}
                      >
                        <Trash2 size={12} />
                        {allSelectedIds.length > 1 && <span>移除 ({allSelectedIds.length})</span>}
                      </button>
                    </div>
                  );
                })()}

                {/* Floating Contextual Tool Options Sub-Capsule when stageWidth < 960 */}
                {!dockLayout.inlineToolOptions && (tool === 'ink' || tool === 'connector') && (
                  <div
                    data-testid="floating-tool-options-pill"
                    className="pointer-events-auto charkle-glass charkle-reveal-bottom rounded-full px-2.5 py-1.5 flex items-center gap-1.5 max-w-full overflow-x-auto charkle-scroll-hidden"
                  >
                    {tool === 'ink' ? penOptionsContent : connectorOptionsContent}
                  </div>
                )}

                {/* Adaptive Bottom Tool Dock + Zoom Controls Row (3 Tiers: wide / medium / compact) */}
                {dockLayout.tier === 'wide' ? (
                  <div className="relative w-full flex items-center justify-center">
                    {toolDockElement}
                    {zoomPillElement && (
                      <div className="absolute right-0 top-1/2 -translate-y-1/2">
                        {zoomPillElement}
                      </div>
                    )}
                  </div>
                ) : dockLayout.tier === 'medium' ? (
                  <div className="w-full flex items-center justify-between gap-2.5">
                    <div className="flex-1 flex justify-center min-w-0">
                      {toolDockElement}
                    </div>
                    {zoomPillElement && <div className="shrink-0">{zoomPillElement}</div>}
                  </div>
                ) : (
                  <div className="w-full flex flex-col items-center gap-2">
                    {zoomPillElement && (
                      <div className="w-full flex justify-end">{zoomPillElement}</div>
                    )}
                    {dockLayout.scrollDockFallback ? (
                      <div
                        data-testid="moodboard-dock-scroll-wrap"
                        className="pointer-events-auto max-w-full overflow-x-auto charkle-scroll-hidden px-0.5"
                      >
                        {toolDockElement}
                      </div>
                    ) : (
                      toolDockElement
                    )}
                  </div>
                )}
              </div>
            );
          })()}

          {/* 10. Drop-Ring Overlay */}
          {showCanvasDropOverlay && (
            <div className="pointer-events-none absolute inset-4 z-40 rounded-[var(--radius-dock-outer)] border-2 border-dashed border-[var(--accent)] bg-[var(--accent-soft)]/50 flex flex-col items-center justify-center gap-2 text-[var(--accent)]">
              <div className="h-11 w-11 rounded-full bg-[var(--bg-elevated)] shadow-sm flex items-center justify-center">
                <Upload size={20} />
              </div>
              <div className="text-[13px] font-semibold">
                {pointerDrag?.kind === 'candidate'
                  ? `松开即可将「${pointerDrag.title}」放入画布`
                  : '松开鼠标即可导入素材并直接上板'}
              </div>
            </div>
          )}
        </div>

        {/* Collapsible 300px Moodboard Right Rail (respects coordinatorStore.inspectorOpen!) */}
        <div
          aria-hidden={!inspectorOpen}
          style={{
            width: inspectorOpen ? 300 : 0,
            opacity: inspectorOpen ? 1 : 0,
          }}
          className={[
            'charkle-drawer-slot shrink-0 min-h-0 h-full overflow-hidden flex justify-start',
            inspectorOpen ? '' : 'pointer-events-none',
          ].join(' ')}
        >
          <CandidatePoolPanel
            onAddAsset={(asset) =>
              addAssetNodeAt(asset.id, getSpawnWorldCenter(), asset, assetsById)
            }
            onExportFigmaBundle={() => void handleExportFigmaBridge()}
            onCopyBoardImage={() => void handleCopyClipboard()}
            onSaveBoardImage={(fmt) => void handleExportImage(fmt)}
            onCopyHex={handleCopyColorHex}
            onSearchByColorHex={handleSearchColorHex}
            exporting={exporting}
          />
        </div>
      </div>

      {/* Node Right-Click Context Menu (Portaled via Popover: viewport-clamped, auto-flipping, isolated from stageRef mousedown) */}
      <Popover
        open={contextMenu !== null && contextMenu.kind === 'node'}
        onOpenChange={(open) => {
          if (!open) setContextMenu(null);
        }}
        anchorPoint={
          contextMenu && contextMenu.kind === 'node'
            ? { x: contextMenu.x, y: contextMenu.y }
            : null
        }
        className="w-[228px] p-1.5 max-h-[calc(100vh-20px)] overflow-y-auto charkle-scroll"
      >
        {contextMenu && contextMenu.kind === 'node' && (() => {
          const targetNode = safeNodes.find((n) => n.id === contextMenu.nodeId);
          if (!targetNode) return null;
          const validTargetIds = contextMenu.targetIds.filter((id) =>
            safeNodes.some((n) => n.id === id),
          );
          const ctxTargetIds = validTargetIds.length > 0 ? validTargetIds : [targetNode.id];
          const isMulti = ctxTargetIds.length > 1;
          const countSuffix = isMulti ? ` (${ctxTargetIds.length} 项)` : '';
          const ctxTargetNodes = safeNodes.filter((n) => ctxTargetIds.includes(n.id));
          const ctxUnlockedIds = ctxTargetNodes.filter((n) => !n.isLocked).map((n) => n.id);
          const ctxAssetIds = Array.from(
            new Set(
              ctxTargetNodes
                .filter((n) => 'assetRef' in n.kind)
                .map((n) => ('assetRef' in n.kind ? n.kind.assetRef.assetID : ''))
                .filter(Boolean),
            ),
          );
          const allLocked = ctxTargetNodes.length > 0 && ctxTargetNodes.every((n) => n.isLocked);
          const anyRotated = ctxTargetNodes.some(
            (n) => !n.isLocked && Math.abs(n.rotationDegrees) > 0.1,
          );
          const assetRef =
            !isMulti && 'assetRef' in targetNode.kind ? targetNode.kind.assetRef : null;
          const noteNode = !isMulti && 'note' in targetNode.kind ? targetNode.kind.note : null;
          const paletteStripNode =
            !isMulti && 'paletteStrip' in targetNode.kind ? targetNode.kind.paletteStrip : null;
          const ctxSwatchHex = paletteStripNode
            ? (
                contextMenu.swatchHex ??
                (paletteStripNode.autoSyncWithBoard && safePalette[0]?.hex
                  ? safePalette[0].hex
                  : paletteStripNode.colors[0]?.hex) ??
                null
              )?.toUpperCase() ?? null
            : null;
          const ctxAssetRecord = assetRef ? assetsById.get(assetRef.assetID) : undefined;
          const ctxAssetMissing = Boolean(assetRef && libraryBootstrapped && !ctxAssetRecord);
          const ctxPlainBookmark = Boolean(
            assetRef && isPlainWebBookmarkAsset(ctxAssetRecord),
          );
          const isGroup = !isMulti && 'groupFrame' in targetNode.kind;
          const hasCrop = Boolean(
            assetRef?.crop && assetRef.crop.width * assetRef.crop.height < 0.99,
          );
          const closeMenu = () => setContextMenu(null);

          return (
            <div
              data-board-context-menu="true"
              data-testid="moodboard-node-context-menu"
              className="flex flex-col gap-0.5 text-[12px] text-[var(--text-primary)]"
            >
              {isMulti && (
                <>
                  <div className="px-2.5 py-1 text-[11px] font-semibold text-[var(--text-secondary)] charkle-tabular">
                    已选 {ctxTargetIds.length} 项画布元素
                  </div>
                  <div className="my-0.5 h-px bg-[var(--border-hairline)]" />
                </>
              )}

              {paletteStripNode && (
                <>
                  {ctxSwatchHex && (
                    <>
                      <button
                        type="button"
                        onClick={() => {
                          closeMenu();
                          handleCopyColorHex(ctxSwatchHex);
                        }}
                        className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                      >
                        <span
                          style={{ backgroundColor: ctxSwatchHex }}
                          className="h-3 w-3 rounded-[3px] border border-black/15 shrink-0"
                        />
                        <span className="truncate">复制色值 {ctxSwatchHex}</span>
                      </button>
                      <button
                        type="button"
                        onClick={() => {
                          closeMenu();
                          handleSearchColorHex(ctxSwatchHex);
                        }}
                        className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                      >
                        <Search size={13} />
                        <span>以此色筛选素材库</span>
                      </button>
                      <div className="my-0.5 h-px bg-[var(--border-hairline)]" />
                    </>
                  )}
                  <button
                    type="button"
                    onClick={() => {
                      closeMenu();
                      const nextSync = !paletteStripNode.autoSyncWithBoard;
                      mutateActiveBoard(
                        (doc) => ({
                          ...doc,
                          nodes: doc.nodes.map((n) =>
                            n.id === targetNode.id && 'paletteStrip' in n.kind
                              ? {
                                  ...n,
                                  kind: {
                                    paletteStrip: {
                                      ...n.kind.paletteStrip,
                                      autoSyncWithBoard: nextSync,
                                      colors:
                                        nextSync && safePalette.length > 0
                                          ? safePalette
                                          : n.kind.paletteStrip.colors,
                                    },
                                  },
                                }
                              : n,
                          ),
                        }),
                        { recordUndo: true, immediateSave: true },
                      );
                    }}
                    className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <RefreshCw size={13} />
                    <span>
                      {paletteStripNode.autoSyncWithBoard
                        ? '关闭自动同步板内色板'
                        : '开启自动同步板内色板'}
                    </span>
                  </button>
                  <div className="my-0.5 h-px bg-[var(--border-hairline)]" />
                </>
              )}

              {noteNode && !targetNode.isLocked && (
                <>
                  <button
                    type="button"
                    onClick={() => {
                      closeMenu();
                      setSelectedNodeIds([targetNode.id]);
                      setEditingGroupId(null);
                      setEditingNoteId(targetNode.id);
                    }}
                    className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <Pencil size={13} />
                    <span>编辑便签</span>
                  </button>
                  <div className="my-0.5 h-px bg-[var(--border-hairline)]" />
                </>
              )}

              {assetRef && (
                <>
                  {!ctxAssetMissing && (
                    <>
                      <button
                        type="button"
                        onClick={() => {
                          closeMenu();
                          openBoardAsset(assetRef.assetID, null);
                        }}
                        className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                      >
                        {ctxPlainBookmark ? <ExternalLink size={13} /> : <Eye size={13} />}
                        <span>{ctxPlainBookmark ? '在默认浏览器中打开' : '快速预览 (Space)'}</span>
                      </button>
                      <button
                        type="button"
                        onClick={() => {
                          closeMenu();
                          void revealAssetInLibrary(assetRef.assetID);
                        }}
                        className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--accent-soft)] hover:text-[var(--accent)] cursor-pointer text-left font-medium"
                      >
                        <Compass size={13} />
                        <span>在素材库中定位</span>
                      </button>
                      <button
                        type="button"
                        onClick={() => {
                          closeMenu();
                          void transport.revealInExplorer(assetRef.assetID).catch((err) => {
                            pushToast({
                              message: err instanceof Error ? err.message : '无法定位本地文件',
                              tone: 'error',
                            });
                          });
                        }}
                        className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                      >
                        <FolderOpen size={13} />
                        <span>在资源管理器中显示</span>
                      </button>
                    </>
                  )}
                  <button
                    type="button"
                    onClick={() => {
                      closeMenu();
                      setSwappingNodeId(targetNode.id);
                      setInspectorOpen(true);
                    }}
                    className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <ArrowLeftRight size={13} />
                    <span>从候选池换一张…</span>
                  </button>
                  {hasCrop && (
                    <button
                      type="button"
                      onClick={() => {
                        closeMenu();
                        mutateActiveBoard(
                          (doc) => ({
                            ...doc,
                            nodes: doc.nodes.map((n) =>
                              n.id === targetNode.id && 'assetRef' in n.kind
                                ? { ...n, kind: { assetRef: { ...n.kind.assetRef, crop: null } } }
                                : n,
                            ),
                          }),
                          { recordUndo: true, immediateSave: true },
                        );
                      }}
                      className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                    >
                      <Crop size={13} />
                      <span>还原完整画面</span>
                    </button>
                  )}
                  <div className="my-0.5 h-px bg-[var(--border-hairline)]" />
                </>
              )}

              {ctxAssetIds.length > 0 && (
                <button
                  type="button"
                  onClick={() => {
                    closeMenu();
                    void handleCopyAssets(ctxAssetIds);
                  }}
                  className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <Copy size={13} />
                  <span>拷贝{countSuffix}</span>
                </button>
              )}
              {(assetRef || isMulti) && (
                <>
                  <button
                    type="button"
                    onClick={() => {
                      closeMenu();
                      void handleCutNodes(ctxTargetIds);
                    }}
                    className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <Scissors size={13} />
                    <span>剪切{countSuffix}</span>
                  </button>
                  <div className="my-0.5 h-px bg-[var(--border-hairline)]" />
                </>
              )}

              {isGroup && (
                <>
                  {!targetNode.isLocked && (
                    <button
                      type="button"
                      onClick={() => {
                        closeMenu();
                        setSelectedNodeIds([targetNode.id]);
                        setEditingNoteId(null);
                        setEditingGroupId(targetNode.id);
                      }}
                      className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                    >
                      <Pencil size={13} />
                      <span>重命名分组</span>
                    </button>
                  )}
                  <button
                    type="button"
                    onClick={() => {
                      closeMenu();
                      reflowGroupFrameNow(targetNode.id);
                    }}
                    className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <Grid2x2 size={13} />
                    <span>自适应缩放排布框内素材</span>
                  </button>
                  <div className="my-0.5 h-px bg-[var(--border-hairline)]" />
                </>
              )}

              {ctxUnlockedIds.length > 0 && (
                <>
                  <button
                    type="button"
                    onClick={() => {
                      closeMenu();
                      rotateNodes(ctxUnlockedIds, 90);
                    }}
                    className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <RotateCw size={13} />
                    <span>顺时针旋转 90° (R){countSuffix}</span>
                  </button>
                  <button
                    type="button"
                    onClick={() => {
                      closeMenu();
                      rotateNodes(ctxUnlockedIds, -90);
                    }}
                    className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <RotateCcw size={13} />
                    <span>逆时针旋转 90° (Shift+R){countSuffix}</span>
                  </button>
                  {anyRotated && (
                    <button
                      type="button"
                      onClick={() => {
                        closeMenu();
                        resetNodesRotation(ctxUnlockedIds);
                      }}
                      className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                    >
                      <Undo2 size={13} />
                      <span>重置旋转角度 (0°){countSuffix}</span>
                    </button>
                  )}
                  <button
                    type="button"
                    onClick={() => {
                      closeMenu();
                      flipNodes(ctxUnlockedIds, true);
                    }}
                    className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <FlipHorizontal2 size={13} />
                    <span>
                      {!isMulti && targetNode.flipHorizontal
                        ? '取消水平翻转'
                        : `水平翻转 (Shift+H)${countSuffix}`}
                    </span>
                  </button>
                  <button
                    type="button"
                    onClick={() => {
                      closeMenu();
                      flipNodes(ctxUnlockedIds, false);
                    }}
                    className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                  >
                    <FlipVertical2 size={13} />
                    <span>
                      {!isMulti && targetNode.flipVertical
                        ? '取消上下翻转'
                        : `上下翻转 (Shift+V)${countSuffix}`}
                    </span>
                  </button>
                  <div className="my-0.5 h-px bg-[var(--border-hairline)]" />
                </>
              )}

              {assetRef && (
                <button
                  type="button"
                  onClick={() => {
                    closeMenu();
                    mutateActiveBoard(
                      (doc) => ({
                        ...doc,
                        nodes: doc.nodes.map((n) =>
                          n.id === targetNode.id && 'assetRef' in n.kind
                            ? {
                                ...n,
                                kind: {
                                  assetRef: {
                                    ...n.kind.assetRef,
                                    weight: n.kind.assetRef.weight >= 2 ? 1 : 2,
                                  },
                                },
                              }
                            : n,
                        ),
                      }),
                      { recordUndo: true, immediateSave: true },
                    );
                  }}
                  className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
                >
                  <Star size={13} />
                  <span>{assetRef.weight >= 2 ? '取消主图 2× 权重' : '设为主图 2× 权重'}</span>
                </button>
              )}

              <button
                type="button"
                onClick={() => {
                  closeMenu();
                  const idSet = new Set(ctxTargetIds);
                  mutateActiveBoard(
                    (doc) => ({
                      ...doc,
                      nodes: doc.nodes.map((n) =>
                        idSet.has(n.id) ? { ...n, isLocked: !allLocked } : n,
                      ),
                    }),
                    { recordUndo: true, immediateSave: true },
                  );
                }}
                className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
              >
                {allLocked ? <Unlock size={13} /> : <Lock size={13} />}
                <span>{allLocked ? `解锁位置${countSuffix}` : `锁定位置${countSuffix}`}</span>
              </button>
              <div className="my-0.5 h-px bg-[var(--border-hairline)]" />
              <button
                type="button"
                onClick={() => {
                  closeMenu();
                  removeBoardNodesWithFeedback(ctxTargetIds);
                }}
                className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--danger-soft)] text-[var(--danger)] cursor-pointer text-left"
              >
                <Trash2 size={13} />
                <span>从情绪板移除{countSuffix}</span>
              </button>
            </div>
          );
        })()}
      </Popover>

      {/* Canvas Right-Click Context Menu (Portaled via Popover) */}
      <Popover
        open={contextMenu !== null && contextMenu.kind === 'canvas'}
        onOpenChange={(open) => {
          if (!open) setContextMenu(null);
        }}
        anchorPoint={
          contextMenu && contextMenu.kind === 'canvas'
            ? { x: contextMenu.x, y: contextMenu.y }
            : null
        }
        className="w-[200px] p-1.5 max-h-[calc(100vh-20px)] overflow-y-auto charkle-scroll"
      >
        {contextMenu && contextMenu.kind === 'canvas' && (
          <div
            data-board-context-menu="true"
            data-testid="moodboard-canvas-context-menu"
            className="flex flex-col gap-0.5 text-[12px] text-[var(--text-primary)]"
          >
            <button
              type="button"
              onClick={() => {
                const pt = contextMenu.worldPt;
                setContextMenu(null);
                handlePasteIntoBoard(pt);
              }}
              className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
            >
              <Clipboard size={13} />
              <span>粘贴到情绪板</span>
            </button>
            <div className="my-0.5 h-px bg-[var(--border-hairline)]" />
            <button
              type="button"
              onClick={() => {
                const pt = contextMenu.worldPt;
                setContextMenu(null);
                addNoteNode('warm', pt);
              }}
              className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
            >
              <StickyNote size={13} />
              <span>添加灵感便签</span>
            </button>
            <button
              type="button"
              onClick={() => {
                const pt = contextMenu.worldPt;
                setContextMenu(null);
                addGroupFrameNode('sand', pt);
              }}
              className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
            >
              <SquareDashed size={13} />
              <span>添加区域分组框</span>
            </button>
            <button
              type="button"
              onClick={() => {
                const pt = contextMenu.worldPt;
                setContextMenu(null);
                addPaletteStripNode(pt);
              }}
              className="w-full h-7.5 px-2.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
            >
              <Palette size={13} />
              <span>添加全板色卡条</span>
            </button>
          </div>
        )}
      </Popover>

      {/* Connector Label Editor Popover */}
      <Popover
        open={editingConnector !== null}
        onOpenChange={(open) => {
          if (!open) setEditingConnector(null);
        }}
        anchorPoint={editingConnector ? { x: editingConnector.x, y: editingConnector.y } : null}
        className="w-[248px] p-3"
      >
        {editingConnector && (
          <div className="flex flex-col gap-2.5 text-[12px]">
            <div className="font-semibold text-[var(--text-primary)]">连线标签</div>
            <input
              type="text"
              autoFocus
              value={editingConnector.draft}
              placeholder="输入说明文字（如：色彩呼应、材质参考）"
              onChange={(e) =>
                setEditingConnector((prev) => (prev ? { ...prev, draft: e.target.value } : null))
              }
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.nativeEvent.isComposing) {
                  updateConnectorLabel(editingConnector.id, editingConnector.draft);
                  setEditingConnector(null);
                }
              }}
              className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
            />
            <div className="flex items-center justify-between">
              <Button
                variant="danger"
                size="xs"
                onClick={() => {
                  removeConnector(editingConnector.id);
                  setSelectedConnectorId(null);
                  setEditingConnector(null);
                }}
              >
                删除连线
              </Button>
              <Button
                variant="primary"
                size="xs"
                onClick={() => {
                  updateConnectorLabel(editingConnector.id, editingConnector.draft);
                  setEditingConnector(null);
                }}
              >
                保存
              </Button>
            </div>
          </div>
        )}
      </Popover>

      {/* Non-Destructive Crop Popover for Selected AssetRef */}
      {selectedSingleNode && 'assetRef' in selectedSingleNode.kind && (
        <Popover
          open={cropOpen}
          onOpenChange={setCropOpen}
          anchorEl={cropBtnRef.current}
          placement="top-center"
          className="w-[248px] p-3"
        >
          {(() => {
            const crop: NormalizedCropRect = selectedSingleNode.kind.assetRef.crop ?? {
              x: 0,
              y: 0,
              width: 1,
              height: 1,
            };
            const updateCrop = (next: NormalizedCropRect | null) => {
              mutateActiveBoard((doc) => ({
                ...doc,
                nodes: doc.nodes.map((n) =>
                  n.id === selectedSingleNode.id && 'assetRef' in n.kind
                    ? { ...n, kind: { assetRef: { ...n.kind.assetRef, crop: next } } }
                    : n,
                ),
              }));
            };
            return (
              <div className="flex flex-col gap-2 text-[11.5px]">
                <div className="flex items-center justify-between font-semibold text-[var(--text-primary)]">
                  <span>非破坏性局部裁切</span>
                  <button
                    type="button"
                    onClick={() => updateCrop(null)}
                    className="text-[var(--accent)] hover:underline cursor-pointer"
                  >
                    重置原图
                  </button>
                </div>
                <div className="flex items-center justify-between gap-2">
                  <span className="text-[var(--text-secondary)]">缩放倍率</span>
                  <CharkleSlider
                    min={0.35}
                    max={1}
                    step={0.05}
                    value={crop.width}
                    onChange={(w) => {
                      updateCrop({
                        x: Math.min(1 - w, crop.x),
                        y: Math.min(1 - w, crop.y),
                        width: w,
                        height: w,
                      });
                    }}
                    ariaLabel="缩放倍率"
                    valueText={`${Math.round(crop.width * 100)}%`}
                    variant="glass"
                    size="sm"
                    className="w-28"
                  />
                </div>
                <div className="flex items-center justify-between gap-2">
                  <span className="text-[var(--text-secondary)]">水平偏移</span>
                  <CharkleSlider
                    min={0}
                    max={Math.max(0, 1 - crop.width)}
                    step={0.02}
                    value={crop.x}
                    disabled={1 - crop.width <= 0.001}
                    onChange={(x) => updateCrop({ ...crop, x })}
                    ariaLabel="水平偏移"
                    valueText={`${Math.round(crop.x * 100)}%`}
                    variant="glass"
                    size="sm"
                    className="w-28"
                  />
                </div>
                <div className="flex items-center justify-between gap-2">
                  <span className="text-[var(--text-secondary)]">垂直偏移</span>
                  <CharkleSlider
                    min={0}
                    max={Math.max(0, 1 - crop.height)}
                    step={0.02}
                    value={crop.y}
                    disabled={1 - crop.height <= 0.001}
                    onChange={(y) => updateCrop({ ...crop, y })}
                    ariaLabel="垂直偏移"
                    valueText={`${Math.round(crop.y * 100)}%`}
                    variant="glass"
                    size="sm"
                    className="w-28"
                  />
                </div>
              </div>
            );
          })()}
        </Popover>
      )}

      {/* Export Popover */}
      <Popover
        open={exportOpen}
        onOpenChange={setExportOpen}
        anchorEl={exportBtnRef.current}
        placement="bottom-end"
        className="w-[310px] p-3.5"
      >
        <div data-testid="moodboard-export-popover" className="flex flex-col gap-3 text-[12px]">
          <div className="text-[13px] font-semibold text-[var(--text-primary)]">
            导出与交付
          </div>

          <div className="flex items-center justify-between">
            <span className="text-[var(--text-secondary)]">分辨率</span>
            <SegmentedControl<'1' | '2'>
              value={exportScale}
              onChange={setExportScale}
              options={[
                { value: '1', label: '1× 标准' },
                { value: '2', label: '2× 高清' },
              ]}
            />
          </div>

          <div className="flex items-center justify-between">
            <span className="text-[var(--text-secondary)]">图片格式</span>
            <SegmentedControl<BoardImageFormat>
              value={exportFormat}
              onChange={setExportFormat}
              options={[
                { value: 'png', label: 'PNG 无损' },
                { value: 'jpeg', label: 'JPG 轻量' },
              ]}
            />
          </div>

          <div className="flex flex-col gap-1.5 text-[var(--text-primary)]">
            <label className="flex items-center justify-between cursor-pointer">
              <span>包含连线与手绘批注</span>
              <input
                type="checkbox"
                checked={exportAnnotations}
                onChange={(e) => setExportAnnotations(e.target.checked)}
                className="accent-[var(--accent)]"
              />
            </label>
            <label className="flex items-center justify-between cursor-pointer">
              <span>包含顶部板内色卡</span>
              <input
                type="checkbox"
                checked={exportPalette}
                onChange={(e) => setExportPalette(e.target.checked)}
                className="accent-[var(--accent)]"
              />
            </label>
            <label className="flex items-center justify-between cursor-pointer">
              <span>深色画布背景</span>
              <input
                type="checkbox"
                checked={exportDark}
                onChange={(e) => setExportDark(e.target.checked)}
                className="accent-[var(--accent)]"
              />
            </label>
          </div>

          <div className="pt-2 border-t border-[var(--border-hairline)] flex flex-col gap-1.5">
            <Button
              variant="secondary"
              size="sm"
              loading={exporting}
              onClick={() => void handleExportImage()}
              className="w-full justify-center"
            >
              <ImageIcon size={14} />
              导出 {exportScale}× {exportFormat.toUpperCase()} 图片
            </Button>
            <Button
              variant="secondary"
              size="sm"
              loading={exporting}
              onClick={() => void handleCopyClipboard()}
              className="w-full justify-center"
            >
              <Clipboard size={14} />
              复制高清图到剪贴板
            </Button>
            <Button
              variant="primary"
              size="sm"
              loading={exporting}
              onClick={() => void handleExportFigmaBridge()}
              className="w-full justify-center"
            >
              <Download size={14} />
              导出 .charkleboard（Figma / FigJam）
            </Button>
          </div>
        </div>
      </Popover>

      <MoodboardGeneratorModal
        open={genOpen}
        onClose={() => setGenOpen(false)}
        existingBoard={activeBoard}
      />
    </div>
  );
};
