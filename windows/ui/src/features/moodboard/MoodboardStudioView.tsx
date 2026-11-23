import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowLeft,
  ArrowUpRight,
  Clipboard,
  Crop,
  Download,
  FlipHorizontal2,
  FlipVertical2,
  Hand,
  Image as ImageIcon,
  Layers,
  LayoutGrid,
  Lock,
  MousePointer2,
  Palette,
  PanelRight,
  PenTool,
  Pin,
  Redo2,
  RotateCw,
  Share2,
  Sparkles,
  SquareDashed,
  StickyNote,
  Trash2,
  Undo2,
  Unlock,
  Wand2,
  ZoomIn,
  ZoomOut,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  Button,
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
  type AssetRecord,
  type BoardImageFormat,
  type BoardNode,
  type BoardPoint,
  type BoardRect,
  type ConnectorStyle,
  type EditorialStyle,
  type GroupTint,
  type InkStrokePoint,
  type MoodboardExportOptions,
  type NormalizedCropRect,
  type NoteStyle,
} from '../../types/domain';
import { CANDIDATE_DRAG_MIME, CandidatePoolPanel } from './CandidatePoolPanel';
import {
  GROUP_TINT_PALETTE,
  NOTE_STYLE_PALETTE,
  buildConnectorSvgPath,
  reflowNodesInsideGroupFrame,
  solveEditorialLayout,
} from './editorial';
import { MoodboardGeneratorModal } from './MoodboardGeneratorModal';

type CanvasTool = 'select' | 'hand' | 'connector' | 'ink';

interface AlignmentGuides {
  vertical: number | null;
  horizontal: number | null;
}

const SNAP_THRESHOLD_PX = 6;
const INK_COLORS = ['#E05A47', '#2A60E0', '#249A4B', '#D9A721', '#18191C', '#F2F3F5'];

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

/**
 * Dual-Mode Moodboard Studio (`Auto Editorial <-> Freeform Infinite Canvas`)
 * implementing M4-R3, M4-R4 & M4-R5 with all 5 element/annotation types, Undo/Redo,
 * 6px alignment guides, Smart Auto-Layout GroupFrame reflow, direct external file drop,
 * high-DPI PNG/JPG export, clipboard copy, and offline `.charkleboard` Figma Bridge export.
 */
export const MoodboardStudioView: React.FC = () => {
  const setDestination = useCoordinatorStore((s) => s.setDestination);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const libraryAssets = useLibraryStore((s) => s.assets);
  const setCriteria = useLibraryStore((s) => s.setCriteria);
  const ingestImageBase64 = useLibraryStore((s) => s.ingestImageBase64);

  const activeBoard = useMoodboardStore((s) => s.activeBoard);
  const historyPast = useMoodboardStore((s) => s.historyPast);
  const historyFuture = useMoodboardStore((s) => s.historyFuture);
  const selectedNodeIds = useMoodboardStore((s) => s.selectedNodeIds);
  const setSelectedNodeIds = useMoodboardStore((s) => s.setSelectedNodeIds);
  const mutateActiveBoard = useMoodboardStore((s) => s.mutateActiveBoard);
  const undo = useMoodboardStore((s) => s.undo);
  const redo = useMoodboardStore((s) => s.redo);
  const addAssetNodeAt = useMoodboardStore((s) => s.addAssetNodeAt);
  const addNoteNode = useMoodboardStore((s) => s.addNoteNode);
  const addGroupFrameNode = useMoodboardStore((s) => s.addGroupFrameNode);
  const addPaletteStripNode = useMoodboardStore((s) => s.addPaletteStripNode);
  const addConnector = useMoodboardStore((s) => s.addConnector);
  const addInkStroke = useMoodboardStore((s) => s.addInkStroke);
  const removeNodes = useMoodboardStore((s) => s.removeNodes);
  const switchBoardMode = useMoodboardStore((s) => s.switchBoardMode);
  const tidyActiveBoard = useMoodboardStore((s) => s.tidyActiveBoard);
  const setBoardPinnedOffline = useMoodboardStore((s) => s.setBoardPinnedOffline);

  const isDark = useResolvedIsDark();
  const transport = getTransport();

  const stageRef = useRef<HTMLDivElement | null>(null);
  const exportBtnRef = useRef<HTMLButtonElement | null>(null);
  const cropBtnRef = useRef<HTMLButtonElement | null>(null);

  const [stageWidth, setStageWidth] = useState(1060);
  const [tool, setTool] = useState<CanvasTool>('select');
  const [poolOpen, setPoolOpen] = useState(true);
  const [genOpen, setGenOpen] = useState(false);
  const [exportOpen, setExportOpen] = useState(false);
  const [cropOpen, setCropOpen] = useState(false);
  const [titleDraft, setTitleDraft] = useState(activeBoard?.title ?? '');

  // Viewport transform in Freeform mode
  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState<BoardPoint>({ x: 0, y: 0 });
  const [spacePressed, setSpacePressed] = useState(false);
  const [guides, setGuides] = useState<AlignmentGuides>({ vertical: null, horizontal: null });

  // Interactive gesture states
  const [panDrag, setPanDrag] = useState<{ startX: number; startY: number; origX: number; origY: number } | null>(null);
  const [marquee, setMarquee] = useState<{ startX: number; startY: number; curX: number; curY: number } | null>(null);
  const [nodeDrag, setNodeDrag] = useState<{
    nodeId: string;
    startClientX: number;
    startClientY: number;
    origFrames: Record<string, BoardRect>;
  } | null>(null);
  const [resizeDrag, setResizeDrag] = useState<{
    nodeId: string;
    startClientX: number;
    startClientY: number;
    origRect: BoardRect;
    enclosedChildIds: string[];
  } | null>(null);

  // Editorial drag-to-reorder ripple tracking
  const [draggingEditorialId, setDraggingEditorialId] = useState<string | null>(null);
  const [hoverEditorialIdx, setHoverEditorialIdx] = useState<number | null>(null);

  // Connector & Ink creation states
  const [pendingConnector, setPendingConnector] = useState<{
    fromNodeID: string;
    fromNormalizedPoint: BoardPoint;
  } | null>(null);
  const [connectorStyle, setConnectorStyle] = useState<ConnectorStyle>('curved');
  const [connectorDashed, setConnectorDashed] = useState(false);
  const [inkColor, setInkColor] = useState(INK_COLORS[0]);
  const [inkWidth, setInkWidth] = useState(3.2);
  const [activeStroke, setActiveStroke] = useState<InkStrokePoint[] | null>(null);

  // Export options state
  const [exportScale, setExportScale] = useState<'1' | '2'>('2');
  const [exportFormat, setExportFormat] = useState<BoardImageFormat>('png');
  const [exportAnnotations, setExportAnnotations] = useState(true);
  const [exportPalette, setExportPalette] = useState(true);
  const [exportDark, setExportDark] = useState(isDark);
  const [exporting, setExporting] = useState(false);

  useEffect(() => {
    setTitleDraft(activeBoard?.title ?? '');
  }, [activeBoard?.id, activeBoard?.title]);

  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const measure = () => {
      if (el.clientWidth > 200) setStageWidth(el.clientWidth);
    };
    measure();
    if (typeof ResizeObserver === 'undefined') return;
    const obs = new ResizeObserver(measure);
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  // Studio keyboard shortcuts: Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z / Delete / Space-pan
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const typing =
        target?.tagName === 'INPUT' || target?.tagName === 'TEXTAREA' || target?.isContentEditable;
      if (typing) return;

      const mod = e.ctrlKey || e.metaKey;
      if (mod && e.key.toLowerCase() === 'z' && !e.shiftKey) {
        e.preventDefault();
        undo();
      } else if ((mod && e.key.toLowerCase() === 'y') || (mod && e.shiftKey && e.key.toLowerCase() === 'z')) {
        e.preventDefault();
        redo();
      } else if ((e.key === 'Delete' || e.key === 'Backspace') && selectedNodeIds.length > 0) {
        e.preventDefault();
        removeNodes(selectedNodeIds);
      } else if (e.code === 'Space' && !e.repeat) {
        setSpacePressed(true);
      } else if (e.key === 'Escape') {
        setPendingConnector(null);
        setTool('select');
      }
    };
    const onKeyUp = (e: KeyboardEvent) => {
      if (e.code === 'Space') setSpacePressed(false);
    };
    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keyup', onKeyUp);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keyup', onKeyUp);
    };
  }, [undo, redo, removeNodes, selectedNodeIds]);

  const assetsById = useMemo(
    () => new Map<string, AssetRecord>(libraryAssets.map((a) => [a.id, a])),
    [libraryAssets],
  );

  const isEditorial = activeBoard ? isAutoEditorialMode(activeBoard.mode) : true;
  const editorialCfg =
    activeBoard && isAutoEditorialMode(activeBoard.mode)
      ? activeBoard.mode.autoEditorial._0
      : { columns: 4, spacing: 16, style: 'balanced' as EditorialStyle, showPaletteStrip: true };

  const editorialSolved = useMemo(() => {
    if (!activeBoard || !isEditorial) return null;
    return solveEditorialLayout(activeBoard.nodes, editorialCfg, stageWidth, assetsById, 28);
  }, [activeBoard, isEditorial, editorialCfg, stageWidth, assetsById]);

  const resolvedFrames = useMemo(() => {
    const map = new Map<string, BoardRect>();
    if (!activeBoard) return map;
    for (const n of activeBoard.nodes) {
      map.set(n.id, (isEditorial ? editorialSolved?.frames[n.id] : n.frame) ?? n.frame);
    }
    return map;
  }, [activeBoard, isEditorial, editorialSolved]);

  const selectedNode = useMemo<BoardNode | null>(() => {
    if (!activeBoard || selectedNodeIds.length !== 1) return null;
    return activeBoard.nodes.find((n) => n.id === selectedNodeIds[0]) ?? null;
  }, [activeBoard, selectedNodeIds]);

  const clientToWorld = (clientX: number, clientY: number): BoardPoint => {
    const el = stageRef.current;
    if (!el) return { x: 0, y: 0 };
    const rect = el.getBoundingClientRect();
    if (isEditorial) {
      return {
        x: clientX - rect.left + el.scrollLeft,
        y: clientY - rect.top + el.scrollTop,
      };
    }
    return {
      x: (clientX - rect.left - pan.x) / zoom,
      y: (clientY - rect.top - pan.y) / zoom,
    };
  };

  // Global mouse move/up for Freeform node drag (with 6px snap guides), resize (with GroupFrame Smart Reflow), pan & ink
  useEffect(() => {
    if (!panDrag && !nodeDrag && !resizeDrag && !marquee && !activeStroke) return;

    const handleMove = (e: MouseEvent) => {
      if (panDrag) {
        setPan({
          x: panDrag.origX + (e.clientX - panDrag.startX),
          y: panDrag.origY + (e.clientY - panDrag.startY),
        });
        return;
      }

      if (activeStroke) {
        const pt = clientToWorld(e.clientX, e.clientY);
        setActiveStroke((prev) => (prev ? [...prev, { x: pt.x, y: pt.y, pressure: 0.5 }] : null));
        return;
      }

      if (marquee) {
        const pt = clientToWorld(e.clientX, e.clientY);
        setMarquee((prev) => (prev ? { ...prev, curX: pt.x, curY: pt.y } : null));
        return;
      }

      if (nodeDrag && activeBoard) {
        let dx = (e.clientX - nodeDrag.startClientX) / zoom;
        let dy = (e.clientY - nodeDrag.startClientY) / zoom;
        const primaryOrig = nodeDrag.origFrames[nodeDrag.nodeId];
        let snapV: number | null = null;
        let snapH: number | null = null;

        if (primaryOrig) {
          const movedIds = new Set(Object.keys(nodeDrag.origFrames));
          const candX = primaryOrig.x + dx;
          const candY = primaryOrig.y + dy;
          const candMidX = candX + primaryOrig.width / 2;
          const candMidY = candY + primaryOrig.height / 2;
          const candMaxX = candX + primaryOrig.width;
          const candMaxY = candY + primaryOrig.height;

          for (const other of activeBoard.nodes) {
            if (movedIds.has(other.id)) continue;
            const f = other.frame;
            const xPairs: Array<[number, number]> = [
              [candX, f.x],
              [candMidX, f.x + f.width / 2],
              [candMaxX, f.x + f.width],
            ];
            for (const [a, b] of xPairs) {
              if (Math.abs(a - b) <= SNAP_THRESHOLD_PX) {
                dx += b - a;
                snapV = b;
                break;
              }
            }
            const yPairs: Array<[number, number]> = [
              [candY, f.y],
              [candMidY, f.y + f.height / 2],
              [candMaxY, f.y + f.height],
            ];
            for (const [a, b] of yPairs) {
              if (Math.abs(a - b) <= SNAP_THRESHOLD_PX) {
                dy += b - a;
                snapH = b;
                break;
              }
            }
          }
        }

        setGuides({ vertical: snapV, horizontal: snapH });
        mutateActiveBoard(
          (doc) => ({
            ...doc,
            nodes: doc.nodes.map((n) => {
              const orig = nodeDrag.origFrames[n.id];
              if (!orig) return n;
              return { ...n, frame: { ...orig, x: orig.x + dx, y: orig.y + dy } };
            }),
          }),
          { recordUndo: false },
        );
        return;
      }

      if (resizeDrag && activeBoard) {
        const dx = (e.clientX - resizeDrag.startClientX) / zoom;
        const dy = (e.clientY - resizeDrag.startClientY) / zoom;
        const nextRect: BoardRect = {
          ...resizeDrag.origRect,
          width: Math.max(96, resizeDrag.origRect.width + dx),
          height: Math.max(72, resizeDrag.origRect.height + dy),
        };

        mutateActiveBoard(
          (doc) => {
            const target = doc.nodes.find((n) => n.id === resizeDrag.nodeId);
            let reflowed: Record<string, BoardRect> = {};
            if (target && 'groupFrame' in target.kind && resizeDrag.enclosedChildIds.length > 0) {
              const children = doc.nodes.filter((n) => resizeDrag.enclosedChildIds.includes(n.id));
              reflowed = reflowNodesInsideGroupFrame(nextRect, children, assetsById);
            }
            return {
              ...doc,
              nodes: doc.nodes.map((n) => {
                if (n.id === resizeDrag.nodeId) return { ...n, frame: nextRect };
                if (reflowed[n.id]) return { ...n, frame: reflowed[n.id] };
                return n;
              }),
            };
          },
          { recordUndo: false },
        );
      }
    };

    const handleUp = () => {
      if (marquee && activeBoard) {
        const left = Math.min(marquee.startX, marquee.curX);
        const right = Math.max(marquee.startX, marquee.curX);
        const top = Math.min(marquee.startY, marquee.curY);
        const bottom = Math.max(marquee.startY, marquee.curY);
        if (right - left > 4 || bottom - top > 4) {
          const hit = activeBoard.nodes
            .filter((n) => {
              const r = resolvedFrames.get(n.id) ?? n.frame;
              return r.x < right && r.x + r.width > left && r.y < bottom && r.y + r.height > top;
            })
            .map((n) => n.id);
          setSelectedNodeIds(hit);
        }
      }
      if (activeStroke && activeStroke.length >= 2) {
        addInkStroke({
          points: activeStroke,
          colorHex: inkColor,
          lineWidth: inkWidth,
          opacity: 0.92,
          zIndex: 1000,
        });
      }
      setPanDrag(null);
      setNodeDrag(null);
      setResizeDrag(null);
      setMarquee(null);
      setActiveStroke(null);
      setGuides({ vertical: null, horizontal: null });
    };

    window.addEventListener('mousemove', handleMove);
    window.addEventListener('mouseup', handleUp);
    return () => {
      window.removeEventListener('mousemove', handleMove);
      window.removeEventListener('mouseup', handleUp);
    };
  }, [
    panDrag,
    nodeDrag,
    resizeDrag,
    marquee,
    activeStroke,
    activeBoard,
    zoom,
    assetsById,
    resolvedFrames,
    inkColor,
    inkWidth,
    mutateActiveBoard,
    setSelectedNodeIds,
    addInkStroke,
  ]);

  if (!activeBoard) return null;

  const currentExportOptions = (): MoodboardExportOptions => ({
    scale: Number(exportScale),
    format: exportFormat,
    includeAnnotations: exportAnnotations,
    includePaletteStrip: exportPalette,
    darkAppearance: exportDark,
    containerWidth: stageWidth,
  });

  const handleExportImage = async () => {
    const ext = exportFormat === 'png' ? 'png' : 'jpg';
    const dest = await transport.saveFileDialog(`${activeBoard.title}.${ext}`, [
      { name: exportFormat.toUpperCase(), extensions: [ext] },
    ]);
    if (!dest) return;
    setExporting(true);
    try {
      const bytes = await transport.exportBoardImageFile(activeBoard, currentExportOptions(), dest);
      setExportOpen(false);
      pushToast({
        message: `已导出 ${exportScale}× ${exportFormat.toUpperCase()}（${Math.round(bytes / 1024)} KB）`,
        tone: 'success',
      });
    } finally {
      setExporting(false);
    }
  };

  const handleCopyClipboard = async () => {
    setExporting(true);
    try {
      await transport.copyBoardImageToClipboard(activeBoard, {
        ...currentExportOptions(),
        format: 'png',
      });
      setExportOpen(false);
      pushToast({
        message: '已复制高清情绪板到剪贴板，可直接 Ctrl+V 粘贴至 Figma / PowerPoint',
        tone: 'success',
      });
    } finally {
      setExporting(false);
    }
  };

  const handleExportFigmaBridge = async () => {
    const dest = await transport.saveFileDialog(`${activeBoard.title}.charkleboard`, [
      { name: 'Charkle Figma Bridge', extensions: ['charkleboard'] },
    ]);
    if (!dest) return;
    setExporting(true);
    try {
      const report = await transport.exportBoardFigmaBridge(
        activeBoard,
        currentExportOptions(),
        dest,
      );
      setExportOpen(false);
      pushToast({
        message: `已导出 .charkleboard（${report.objectCount} 对象 / ${report.imageCount} 图片 / ${report.connectorCount} 连线）`,
        tone: 'success',
        durationMs: 4800,
      });
    } finally {
      setExporting(false);
    }
  };

  const handleCanvasDrop = async (e: React.DragEvent) => {
    e.preventDefault();
    const dropPt = clientToWorld(e.clientX, e.clientY);

    // 1. Candidate dragged from right CandidatePoolPanel
    const candId = e.dataTransfer.getData(CANDIDATE_DRAG_MIME);
    if (candId) {
      addAssetNodeAt(candId, dropPt);
      return;
    }

    // 2. External files dropped from Windows Explorer -> auto-ingest to Inbox + insert node at drop coords
    const files = Array.from(e.dataTransfer.files);
    if (files.length > 0) {
      let offset = 0;
      for (const file of files) {
        const dataUrl = await new Promise<string>((resolve) => {
          const reader = new FileReader();
          reader.onload = () => resolve(String(reader.result ?? ''));
          reader.readAsDataURL(file);
        });
        const base64 = dataUrl.includes(',') ? dataUrl.split(',')[1] : dataUrl;
        if (base64) {
          const created = await ingestImageBase64(base64, file.name, null, null);
          if (created[0]) {
            addAssetNodeAt(created[0].id, { x: dropPt.x + offset * 28, y: dropPt.y + offset * 24 });
            offset += 1;
          }
        }
      }
    }
  };

  // Reorder helper for Auto Editorial drag-to-reorder
  const reorderEditorialNode = (fromId: string, toId: string) => {
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
  };

  const orderedRenderNodes = [...activeBoard.nodes].sort((a, b) => {
    const ag = 'groupFrame' in a.kind ? 0 : 1;
    const bg = 'groupFrame' in b.kind ? 0 : 1;
    if (ag !== bg) return ag - bg;
    if (a.zIndex !== b.zIndex) return a.zIndex - b.zIndex;
    return a.editorialOrder - b.editorialOrder;
  });

  const editorialOrderIndexMap = new Map<string, number>(
    (editorialSolved?.orderedNodeIds ?? []).map((id, idx) => [id, idx]),
  );

  return (
    <div
      data-testid="moodboard-studio-view"
      className="flex-1 min-w-0 min-h-0 flex flex-col bg-[var(--bg-gallery)] overflow-hidden"
    >
      {/* Top Studio Header Bar */}
      <header className="shrink-0 h-[48px] px-3.5 border-b border-[var(--border-hairline)] bg-[var(--bg-elevated)]/80 flex items-center justify-between gap-2 select-none">
        <div className="flex items-center gap-2 min-w-0">
          <Button
            variant="ghost"
            size="xs"
            onClick={() => setDestination({ type: 'moodboardsHome' })}
          >
            <ArrowLeft size={14} />
            情绪板
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
            className="h-7 px-2 rounded-[var(--radius-card-inner)] bg-transparent hover:bg-[var(--bg-subtle)] focus:bg-[var(--bg-inspector-field)] border border-transparent focus:border-[var(--accent)] text-[14px] font-semibold text-[var(--text-primary)] outline-none max-w-[240px] truncate"
          />

          <SegmentedControl<'autoEditorial' | 'freeform'>
            value={isEditorial ? 'autoEditorial' : 'freeform'}
            onChange={(mode) => switchBoardMode(mode, stageWidth, assetsById)}
            ariaLabel="情绪板画布模式"
            size="xs"
            options={[
              { value: 'autoEditorial', label: '自动编排', icon: <LayoutGrid size={12.5} /> },
              { value: 'freeform', label: '自由画布', icon: <Layers size={12.5} /> },
            ]}
          />

          {isEditorial && (
            <SegmentedControl<EditorialStyle>
              value={editorialCfg.style}
              onChange={(style) =>
                switchBoardMode('autoEditorial', stageWidth, assetsById, { style })
              }
              ariaLabel="自动编排风格"
              size="xs"
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
          >
            <Undo2 size={14.5} />
          </Button>
          <Button
            variant="ghost"
            size="icon"
            disabled={historyFuture.length === 0}
            onClick={redo}
            aria-label="重做"
            title="重做 (Ctrl+Y)"
          >
            <Redo2 size={14.5} />
          </Button>

          {!isEditorial && (
            <Button
              variant="secondary"
              size="xs"
              onClick={() => tidyActiveBoard(assetsById)}
              title="一键对齐整理所选或全部画布对象"
            >
              <Wand2 size={12.5} />
              整理对齐
            </Button>
          )}

          <Button
            variant="secondary"
            size="xs"
            onClick={() => setGenOpen(true)}
            title="打开 4+1 智能补充与重排生成器"
          >
            <Sparkles size={12.5} />
            智能策展
          </Button>

          <Button
            variant={activeBoard.pinnedOffline ? 'primary' : 'ghost'}
            size="icon"
            onClick={() => void setBoardPinnedOffline(activeBoard.id, !activeBoard.pinnedOffline)}
            aria-label="离线常驻"
            title={activeBoard.pinnedOffline ? '已离线常驻' : '设为离线常驻'}
          >
            <Pin size={14} />
          </Button>

          <Button
            ref={exportBtnRef}
            variant="primary"
            size="xs"
            onClick={() => setExportOpen((v) => !v)}
          >
            <Download size={13} />
            导出
          </Button>

          <Button
            variant="ghost"
            size="icon"
            active={poolOpen}
            onClick={() => setPoolOpen((v) => !v)}
            aria-label="切换候选替换池"
            title="显示 / 隐藏候选替换池"
          >
            <PanelRight size={15} />
          </Button>
        </div>
      </header>

      {/* Main Workspace: Stage + Collapsible Candidate Pool */}
      <div className="flex-1 min-h-0 flex overflow-hidden relative">
        <div
          ref={stageRef}
          data-testid="moodboard-canvas-stage"
          data-board-mode={isEditorial ? 'autoEditorial' : 'freeform'}
          onDragOver={(e) => e.preventDefault()}
          onDrop={(e) => void handleCanvasDrop(e)}
          onWheel={(e) => {
            if (!isEditorial && (e.ctrlKey || Math.abs(e.deltaY) > 0)) {
              e.preventDefault();
              const factor = e.deltaY < 0 ? 1.1 : 0.9;
              setZoom((z) => Math.max(0.25, Math.min(3, Number((z * factor).toFixed(2)))));
            }
          }}
          onMouseDown={(e) => {
            if ((e.target as HTMLElement).closest('[data-board-node-id]')) return;
            if (!isEditorial && (tool === 'hand' || spacePressed || e.button === 1)) {
              e.preventDefault();
              setPanDrag({ startX: e.clientX, startY: e.clientY, origX: pan.x, origY: pan.y });
              return;
            }
            if (!isEditorial && tool === 'ink' && e.button === 0) {
              const pt = clientToWorld(e.clientX, e.clientY);
              setActiveStroke([{ x: pt.x, y: pt.y, pressure: 0.5 }]);
              return;
            }
            if (e.button === 0) {
              setSelectedNodeIds([]);
              setPendingConnector(null);
              if (!isEditorial) {
                const pt = clientToWorld(e.clientX, e.clientY);
                setMarquee({ startX: pt.x, startY: pt.y, curX: pt.x, curY: pt.y });
              }
            }
          }}
          className={[
            'relative flex-1 min-w-0 min-h-0 bg-[var(--bg-gallery)] select-none',
            isEditorial ? 'overflow-y-auto charkle-scroll' : 'overflow-hidden',
            !isEditorial && (tool === 'hand' || spacePressed)
              ? 'cursor-grab active:cursor-grabbing'
              : !isEditorial && tool === 'ink'
                ? 'cursor-crosshair'
                : 'cursor-default',
          ].join(' ')}
        >
          {/* World Container (GPU-composited translate3d + scale) */}
          <div
            style={
              isEditorial
                ? {
                    position: 'relative',
                    width: '100%',
                    height: Math.max(editorialSolved?.contentSize.height ?? 560, 560),
                  }
                : {
                    position: 'absolute',
                    inset: 0,
                    transformOrigin: '0 0',
                    transform: `translate3d(${pan.x}px, ${pan.y}px, 0) scale(${zoom})`,
                  }
            }
          >
            {/* 6px Smart Alignment Guides */}
            {!isEditorial && guides.vertical !== null && (
              <div
                aria-hidden="true"
                className="pointer-events-none absolute top-[-2000px] bottom-[-2000px] w-px bg-[var(--accent)] z-[900]"
                style={{ left: guides.vertical }}
              />
            )}
            {!isEditorial && guides.horizontal !== null && (
              <div
                aria-hidden="true"
                className="pointer-events-none absolute left-[-2000px] right-[-2000px] h-px bg-[var(--accent)] z-[900]"
                style={{ top: guides.horizontal }}
              />
            )}

            {/* Render All 4 Node Types: GroupFrame, AssetRef, Note, PaletteStrip */}
            {orderedRenderNodes.map((node) => {
              const rect = resolvedFrames.get(node.id) ?? node.frame;
              const selected = selectedNodeIds.includes(node.id);
              const edIdx = editorialOrderIndexMap.get(node.id) ?? 0;

              // Neighbor ripple motion in Auto Editorial drag-to-reorder (DESIGN.md: A * 0.7^n, 24ms * n)
              let rippleOffsetY = 0;
              let rippleDelayMs = 0;
              if (isEditorial && draggingEditorialId && hoverEditorialIdx !== null && node.id !== draggingEditorialId) {
                const dist = Math.abs(edIdx - hoverEditorialIdx);
                if (dist > 0 && dist <= 4) {
                  rippleOffsetY = Math.round(6 * Math.pow(0.7, dist));
                  rippleDelayMs = 24 * dist;
                }
              }

              const startDragNode = (e: React.MouseEvent) => {
                if (e.button !== 0) return;
                e.stopPropagation();

                // Connector tool mode (supports pinpoint normalized internal anchor callouts!)
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
                      label: '呼应',
                      colorHex: '#5C6B73',
                      style: connectorStyle,
                      dashed: connectorDashed,
                    });
                    setPendingConnector(null);
                  }
                  return;
                }

                const nextSelected =
                  e.ctrlKey || e.metaKey
                    ? selected
                      ? selectedNodeIds.filter((id) => id !== node.id)
                      : [...selectedNodeIds, node.id]
                    : selected
                      ? selectedNodeIds
                      : [node.id];
                setSelectedNodeIds(nextSelected);

                if (isEditorial || node.isLocked) return;

                // Record undo snapshot before drag starts
                mutateActiveBoard((doc) => doc, { recordUndo: true });

                const moveIds = new Set(nextSelected);
                // If dragging a GroupFrame, move all enclosed child nodes together!
                if ('groupFrame' in node.kind) {
                  for (const other of activeBoard.nodes) {
                    if (other.id !== node.id && !('groupFrame' in other.kind)) {
                      if (isRectInsideGroup(other.frame, node.frame)) {
                        moveIds.add(other.id);
                      }
                    }
                  }
                }
                const origFrames: Record<string, BoardRect> = {};
                for (const id of moveIds) {
                  const found = activeBoard.nodes.find((n) => n.id === id);
                  if (found && !found.isLocked) origFrames[id] = { ...found.frame };
                }
                setNodeDrag({
                  nodeId: node.id,
                  startClientX: e.clientX,
                  startClientY: e.clientY,
                  origFrames,
                });
              };

              return (
                <div
                  key={node.id}
                  data-board-node-id={node.id}
                  draggable={isEditorial && !node.isLocked}
                  onDragStart={(e) => {
                    if (!isEditorial) return;
                    setDraggingEditorialId(node.id);
                    e.dataTransfer.setData('text/plain', node.id);
                  }}
                  onDragOver={(e) => {
                    if (!isEditorial || !draggingEditorialId) return;
                    e.preventDefault();
                    setHoverEditorialIdx(edIdx);
                  }}
                  onDrop={(e) => {
                    if (!isEditorial || !draggingEditorialId) return;
                    e.preventDefault();
                    e.stopPropagation();
                    reorderEditorialNode(draggingEditorialId, node.id);
                    setDraggingEditorialId(null);
                    setHoverEditorialIdx(null);
                  }}
                  onDragEnd={() => {
                    setDraggingEditorialId(null);
                    setHoverEditorialIdx(null);
                  }}
                  onMouseDown={startDragNode}
                  style={{
                    position: 'absolute',
                    left: 0,
                    top: 0,
                    width: rect.width,
                    height: rect.height,
                    zIndex: 'groupFrame' in node.kind ? 1 : 10 + Math.max(0, node.zIndex),
                    transform: `translate3d(${rect.x}px, ${rect.y + rippleOffsetY}px, 0) rotate(${node.rotationDegrees}deg) scaleX(${node.flipHorizontal ? -1 : 1}) scaleY(${node.flipVertical ? -1 : 1})`,
                    transition:
                      nodeDrag || resizeDrag
                        ? 'none'
                        : `transform var(--duration-move) var(--ease-out-strong) ${rippleDelayMs}ms, width var(--duration-move) var(--ease-out-strong), height var(--duration-move) var(--ease-out-strong)`,
                  }}
                  className={[
                    'group rounded-[var(--radius-card-outer)]',
                    selected
                      ? 'ring-2 ring-[var(--accent)] ring-offset-2 ring-offset-[var(--bg-gallery)]'
                      : '',
                  ].join(' ')}
                >
                  {/* 1. GroupFrame */}
                  {'groupFrame' in node.kind && (
                    <div
                      style={{
                        backgroundColor: isDark
                          ? GROUP_TINT_PALETTE[node.kind.groupFrame.tint].bgDark
                          : GROUP_TINT_PALETTE[node.kind.groupFrame.tint].bgLight,
                        borderColor: GROUP_TINT_PALETTE[node.kind.groupFrame.tint].accent,
                      }}
                      className="w-full h-full rounded-[var(--radius-settings-outer)] border border-dashed flex flex-col overflow-hidden"
                    >
                      <div className="px-3 py-2 flex items-center justify-between gap-2">
                        <input
                          type="text"
                          value={node.kind.groupFrame.title}
                          onMouseDown={(e) => e.stopPropagation()}
                          onChange={(e) => {
                            const val = e.target.value;
                            mutateActiveBoard((doc) => ({
                              ...doc,
                              nodes: doc.nodes.map((n) =>
                                n.id === node.id && 'groupFrame' in n.kind
                                  ? { ...n, kind: { groupFrame: { ...n.kind.groupFrame, title: val } } }
                                  : n,
                              ),
                            }));
                          }}
                          className="bg-transparent text-[12.5px] font-semibold text-[var(--text-primary)] outline-none flex-1 min-w-0"
                        />
                        <span className="text-[10.5px] text-[var(--text-tertiary)]">分组区域</span>
                      </div>
                    </div>
                  )}

                  {/* 2. AssetRef */}
                  {'assetRef' in node.kind && (() => {
                    const refKind = node.kind.assetRef;
                    const asset = assetsById.get(refKind.assetID);
                    const crop = refKind.crop;
                    const cropStyle: React.CSSProperties =
                      crop && crop.width > 0.05 && crop.height > 0.05
                        ? {
                            width: `${100 / crop.width}%`,
                            height: `${100 / crop.height}%`,
                            transform: `translate(-${crop.x * 100}%, -${crop.y * 100}%)`,
                            maxWidth: 'none',
                          }
                        : { width: '100%', height: '100%' };

                    return (
                      <div className="w-full h-full rounded-[var(--radius-card-outer)] overflow-hidden bg-[var(--bg-elevated)] ring-1 ring-[var(--border-hairline)] relative">
                        {asset?.mediaKind === 'video' ? (
                          <video
                            src={transport.originalUrl(refKind.assetID, { cachedOnly: true })}
                            poster={transport.thumbnailUrl(refKind.assetID, 'preview1400')}
                            muted
                            loop={refKind.autoplayLoop}
                            autoPlay={refKind.autoplayLoop}
                            playsInline
                            className="w-full h-full object-cover"
                          />
                        ) : (
                          <img
                            src={transport.thumbnailUrl(refKind.assetID, 'preview1400')}
                            alt={asset?.title ?? '素材'}
                            draggable={false}
                            style={cropStyle}
                            className="object-cover"
                          />
                        )}
                        {refKind.weight >= 2 && (
                          <span className="absolute top-2 left-2 px-1.5 py-0.5 rounded bg-black/60 text-white text-[10px] font-semibold">
                            Hero
                          </span>
                        )}
                        {node.isLocked && (
                          <span className="absolute top-2 right-2 h-5 w-5 rounded bg-black/60 text-white inline-flex items-center justify-center">
                            <Lock size={11} />
                          </span>
                        )}
                      </div>
                    );
                  })()}

                  {/* 3. Note */}
                  {'note' in node.kind && (() => {
                    const noteData = node.kind.note;
                    const st = NOTE_STYLE_PALETTE[noteData.style] ?? NOTE_STYLE_PALETTE.paper;
                    return (
                      <div
                        style={{
                          backgroundColor: st.bg,
                          color: st.fg,
                          borderColor: st.border,
                        }}
                        className="w-full h-full rounded-[var(--radius-card-outer)] border p-3 flex flex-col gap-1.5 shadow-xs"
                      >
                        <input
                          type="text"
                          value={noteData.title ?? ''}
                          placeholder="便签标题"
                          onMouseDown={(e) => e.stopPropagation()}
                          onChange={(e) => {
                            const val = e.target.value;
                            mutateActiveBoard((doc) => ({
                              ...doc,
                              nodes: doc.nodes.map((n) =>
                                n.id === node.id && 'note' in n.kind
                                  ? { ...n, kind: { note: { ...n.kind.note, title: val } } }
                                  : n,
                              ),
                            }));
                          }}
                          className="bg-transparent font-semibold text-[13px] outline-none"
                        />
                        <textarea
                          value={noteData.text}
                          onMouseDown={(e) => e.stopPropagation()}
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
                          style={{ fontSize: noteData.fontSize }}
                          className="flex-1 bg-transparent resize-none outline-none leading-relaxed"
                        />
                      </div>
                    );
                  })()}

                  {/* 4. PaletteStrip */}
                  {'paletteStrip' in node.kind && (() => {
                    const pal = node.kind.paletteStrip;
                    const swatches =
                      pal.autoSyncWithBoard && activeBoard.extractedPalette.length > 0
                        ? activeBoard.extractedPalette
                        : pal.colors.length > 0
                          ? pal.colors
                          : [{ hex: '#2A60E0', l: 44, a: 18, b: -58, proportion: 1 }];
                    return (
                      <div className="w-full h-full rounded-[var(--radius-card-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-2 flex items-stretch gap-1.5 shadow-xs">
                        {swatches.slice(0, 7).map((sw) => (
                          <button
                            key={sw.hex}
                            type="button"
                            onMouseDown={(e) => e.stopPropagation()}
                            onClick={() => {
                              void navigator.clipboard?.writeText(sw.hex);
                              pushToast({
                                message: `已复制色值 ${sw.hex}（双击可反搜同色素材）`,
                                tone: 'info',
                                durationMs: 2200,
                              });
                            }}
                            onDoubleClick={() => {
                              setDestination({ type: 'allItems' });
                              void setCriteria({ selectedColorHex: sw.hex }, { type: 'allItems' });
                            }}
                            style={{ backgroundColor: sw.hex }}
                            className="flex-1 rounded-[var(--radius-card-inner)] border border-black/10 flex items-end justify-center pb-1 cursor-pointer"
                            title={`${sw.hex} · 单击复制 / 双击反搜`}
                          >
                            <span className="px-1 rounded bg-black/45 text-white text-[10px] charkle-mono">
                              {sw.hex}
                            </span>
                          </button>
                        ))}
                      </div>
                    );
                  })()}

                  {/* Corner Resize Handle in Freeform mode */}
                  {!isEditorial && selected && !node.isLocked && (
                    <div
                      role="presentation"
                      onMouseDown={(e) => {
                        e.stopPropagation();
                        mutateActiveBoard((doc) => doc, { recordUndo: true });
                        const enclosedChildIds =
                          'groupFrame' in node.kind
                            ? activeBoard.nodes
                                .filter(
                                  (other) =>
                                    other.id !== node.id &&
                                    !('groupFrame' in other.kind) &&
                                    isRectInsideGroup(other.frame, node.frame),
                                )
                                .map((o) => o.id)
                            : [];
                        setResizeDrag({
                          nodeId: node.id,
                          startClientX: e.clientX,
                          startClientY: e.clientY,
                          origRect: { ...node.frame },
                          enclosedChildIds,
                        });
                      }}
                      className="absolute -bottom-1.5 -right-1.5 h-3.5 w-3.5 rounded-full bg-[var(--accent)] border-2 border-white shadow cursor-nwse-resize z-40"
                    />
                  )}
                </div>
              );
            })}

            {/* 5. SVG Annotation Layer: BoardConnectors + InkStrokes */}
            <svg
              aria-hidden="true"
              className="pointer-events-none absolute inset-0 overflow-visible z-[850]"
              width="1"
              height="1"
            >
              <defs>
                <marker
                  id="charkle-arrow"
                  viewBox="0 0 10 10"
                  refX="8"
                  refY="5"
                  markerWidth="6"
                  markerHeight="6"
                  orient="auto-start-reverse"
                >
                  <path d="M 0 1 L 10 5 L 0 9 z" fill="#5C6B73" />
                </marker>
              </defs>

              {activeBoard.connectors.map((conn) => {
                const fr = resolvedFrames.get(conn.fromNodeID);
                const tr = resolvedFrames.get(conn.toNodeID);
                if (!fr || !tr) return null;
                const geom = buildConnectorSvgPath(conn, fr, tr);
                return (
                  <g key={conn.id}>
                    <path
                      d={geom.path}
                      fill="none"
                      stroke={conn.colorHex}
                      strokeWidth={2.2}
                      strokeDasharray={conn.dashed ? '6 5' : undefined}
                      markerEnd="url(#charkle-arrow)"
                    />
                    {conn.fromNormalizedPoint && (
                      <circle cx={geom.start.x} cy={geom.start.y} r={4} fill={conn.colorHex} />
                    )}
                    {conn.label && (
                      <g transform={`translate(${geom.mid.x}, ${geom.mid.y})`}>
                        <rect
                          x={-34}
                          y={-11}
                          width={68}
                          height={22}
                          rx={11}
                          fill="var(--bg-elevated)"
                          stroke="var(--border-hairline)"
                        />
                        <text
                          textAnchor="middle"
                          dominantBaseline="central"
                          fill="var(--text-primary)"
                          fontSize={11}
                        >
                          {conn.label}
                        </text>
                      </g>
                    )}
                  </g>
                );
              })}

              {activeBoard.inkStrokes.map((stroke) => {
                if (stroke.points.length < 2) return null;
                const d = stroke.points
                  .map((p, idx) => `${idx === 0 ? 'M' : 'L'} ${p.x} ${p.y}`)
                  .join(' ');
                return (
                  <path
                    key={stroke.id}
                    d={d}
                    fill="none"
                    stroke={stroke.colorHex}
                    strokeWidth={stroke.lineWidth}
                    strokeOpacity={stroke.opacity}
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                );
              })}

              {activeStroke && activeStroke.length >= 2 && (
                <path
                  d={activeStroke.map((p, i) => `${i === 0 ? 'M' : 'L'} ${p.x} ${p.y}`).join(' ')}
                  fill="none"
                  stroke={inkColor}
                  strokeWidth={inkWidth}
                  strokeOpacity={0.92}
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              )}
            </svg>

            {/* Marquee box-select rectangle */}
            {marquee && (
              <div
                aria-hidden="true"
                className="pointer-events-none absolute border border-[var(--accent)] bg-[var(--accent-soft)] z-[950]"
                style={{
                  left: Math.min(marquee.startX, marquee.curX),
                  top: Math.min(marquee.startY, marquee.curY),
                  width: Math.abs(marquee.curX - marquee.startX),
                  height: Math.abs(marquee.curY - marquee.startY),
                }}
              />
            )}
          </div>

          {/* Selected Node Floating Context Bar */}
          {selectedNode && (
            <div className="charkle-glass absolute top-3 left-1/2 -translate-x-1/2 z-30 rounded-full px-2.5 py-1 flex items-center gap-1 text-[11.5px]">
              {'assetRef' in selectedNode.kind && (
                <>
                  <button
                    type="button"
                    onClick={() =>
                      mutateActiveBoard((doc) => ({
                        ...doc,
                        nodes: doc.nodes.map((n) =>
                          n.id === selectedNode.id && 'assetRef' in n.kind
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
                      }))
                    }
                    className={[
                      'charkle-pressable h-6 px-2 rounded-full cursor-pointer',
                      selectedNode.kind.assetRef.weight >= 2
                        ? 'bg-[var(--accent)] text-white font-medium'
                        : 'hover:bg-[var(--bg-subtle)] text-[var(--text-primary)]',
                    ].join(' ')}
                  >
                    Hero 2×
                  </button>
                  <button
                    ref={cropBtnRef}
                    type="button"
                    onClick={() => setCropOpen((v) => !v)}
                    className="charkle-pressable h-6 px-2 rounded-full hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] inline-flex items-center gap-1 cursor-pointer"
                  >
                    <Crop size={12} />
                    裁切
                  </button>
                  <button
                    type="button"
                    onClick={() =>
                      void transport.startOutboundDrag([
                        'assetRef' in selectedNode.kind ? selectedNode.kind.assetRef.assetID : '',
                      ])
                    }
                    className="charkle-pressable h-6 px-2 rounded-full hover:bg-[var(--bg-subtle)] text-[var(--text-primary)] inline-flex items-center gap-1 cursor-pointer"
                  >
                    <Share2 size={12} />
                    拖出
                  </button>
                </>
              )}

              {'note' in selectedNode.kind && (
                <div className="flex items-center gap-1 px-1">
                  {(Object.keys(NOTE_STYLE_PALETTE) as NoteStyle[]).map((st) => (
                    <button
                      key={st}
                      type="button"
                      title={NOTE_STYLE_PALETTE[st].label}
                      onClick={() =>
                        mutateActiveBoard((doc) => ({
                          ...doc,
                          nodes: doc.nodes.map((n) =>
                            n.id === selectedNode.id && 'note' in n.kind
                              ? { ...n, kind: { note: { ...n.kind.note, style: st } } }
                              : n,
                          ),
                        }))
                      }
                      style={{ backgroundColor: NOTE_STYLE_PALETTE[st].bg }}
                      className="h-4 w-4 rounded-full border border-black/20 cursor-pointer"
                    />
                  ))}
                </div>
              )}

              {'groupFrame' in selectedNode.kind && (
                <div className="flex items-center gap-1 px-1">
                  {(Object.keys(GROUP_TINT_PALETTE) as GroupTint[]).map((tint) => (
                    <button
                      key={tint}
                      type="button"
                      title={GROUP_TINT_PALETTE[tint].label}
                      onClick={() =>
                        mutateActiveBoard((doc) => ({
                          ...doc,
                          nodes: doc.nodes.map((n) =>
                            n.id === selectedNode.id && 'groupFrame' in n.kind
                              ? { ...n, kind: { groupFrame: { ...n.kind.groupFrame, tint } } }
                              : n,
                          ),
                        }))
                      }
                      style={{ backgroundColor: GROUP_TINT_PALETTE[tint].accent }}
                      className="h-4 w-4 rounded-full border border-black/20 cursor-pointer"
                    />
                  ))}
                </div>
              )}

              {!isEditorial && (
                <>
                  <button
                    type="button"
                    title="旋转 90°"
                    onClick={() =>
                      mutateActiveBoard((doc) => ({
                        ...doc,
                        nodes: doc.nodes.map((n) =>
                          n.id === selectedNode.id
                            ? { ...n, rotationDegrees: (n.rotationDegrees + 90) % 360 }
                            : n,
                        ),
                      }))
                    }
                    className="charkle-pressable h-6 w-6 rounded-full hover:bg-[var(--bg-subtle)] inline-flex items-center justify-center cursor-pointer"
                  >
                    <RotateCw size={12} />
                  </button>
                  <button
                    type="button"
                    title="水平翻转"
                    onClick={() =>
                      mutateActiveBoard((doc) => ({
                        ...doc,
                        nodes: doc.nodes.map((n) =>
                          n.id === selectedNode.id
                            ? { ...n, flipHorizontal: !n.flipHorizontal }
                            : n,
                        ),
                      }))
                    }
                    className="charkle-pressable h-6 w-6 rounded-full hover:bg-[var(--bg-subtle)] inline-flex items-center justify-center cursor-pointer"
                  >
                    <FlipHorizontal2 size={12} />
                  </button>
                  <button
                    type="button"
                    title="垂直翻转"
                    onClick={() =>
                      mutateActiveBoard((doc) => ({
                        ...doc,
                        nodes: doc.nodes.map((n) =>
                          n.id === selectedNode.id
                            ? { ...n, flipVertical: !n.flipVertical }
                            : n,
                        ),
                      }))
                    }
                    className="charkle-pressable h-6 w-6 rounded-full hover:bg-[var(--bg-subtle)] inline-flex items-center justify-center cursor-pointer"
                  >
                    <FlipVertical2 size={12} />
                  </button>
                </>
              )}

              <button
                type="button"
                title={selectedNode.isLocked ? '解锁' : '锁定位置'}
                onClick={() =>
                  mutateActiveBoard((doc) => ({
                    ...doc,
                    nodes: doc.nodes.map((n) =>
                      n.id === selectedNode.id ? { ...n, isLocked: !n.isLocked } : n,
                    ),
                  }))
                }
                className="charkle-pressable h-6 w-6 rounded-full hover:bg-[var(--bg-subtle)] inline-flex items-center justify-center cursor-pointer"
              >
                {selectedNode.isLocked ? <Unlock size={12} /> : <Lock size={12} />}
              </button>

              <button
                type="button"
                title="删除节点"
                aria-label="删除选中节点"
                onClick={() => removeNodes(selectedNodeIds)}
                className="charkle-pressable h-6 w-6 rounded-full hover:bg-[var(--danger-soft)] text-[var(--danger)] inline-flex items-center justify-center cursor-pointer"
              >
                <Trash2 size={12} />
              </button>
            </div>
          )}

          {/* Bottom Floating Studio Tools Dock */}
          <div className="charkle-glass absolute bottom-4 left-1/2 -translate-x-1/2 z-30 rounded-[var(--radius-dock-outer)] px-2 py-1.5 flex items-center gap-1 text-[12px]">
            <button
              type="button"
              onClick={() => setTool('select')}
              title="选择工具"
              aria-label="选择工具"
              className={[
                'charkle-pressable h-8 w-8 rounded-[var(--radius-dock-inner)] inline-flex items-center justify-center cursor-pointer',
                tool === 'select' ? 'bg-[var(--accent)] text-white' : 'text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)]',
              ].join(' ')}
            >
              <MousePointer2 size={15} />
            </button>

            {!isEditorial && (
              <button
                type="button"
                onClick={() => setTool('hand')}
                title="抓手平移画布 (空格+拖拽)"
                aria-label="平移工具"
                className={[
                  'charkle-pressable h-8 w-8 rounded-[var(--radius-dock-inner)] inline-flex items-center justify-center cursor-pointer',
                  tool === 'hand' ? 'bg-[var(--accent)] text-white' : 'text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)]',
                ].join(' ')}
              >
                <Hand size={15} />
              </button>
            )}

            <div className="h-4 w-px bg-[var(--border-hairline)] mx-0.5" />

            <button
              type="button"
              onClick={() => addNoteNode('warm')}
              title="添加灵感便签"
              aria-label="添加便签"
              className="charkle-pressable h-8 px-2 rounded-[var(--radius-dock-inner)] inline-flex items-center gap-1 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              <StickyNote size={14} />
              <span className="hidden sm:inline">便签</span>
            </button>

            <button
              type="button"
              onClick={() => addGroupFrameNode('sand')}
              title="添加智能分组框（缩放自动重排子项）"
              aria-label="添加分组框"
              className="charkle-pressable h-8 px-2 rounded-[var(--radius-dock-inner)] inline-flex items-center gap-1 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              <SquareDashed size={14} />
              <span className="hidden sm:inline">分组</span>
            </button>

            <button
              type="button"
              onClick={() => addPaletteStripNode()}
              title="添加板内色卡条"
              aria-label="添加色卡条"
              className="charkle-pressable h-8 px-2 rounded-[var(--radius-dock-inner)] inline-flex items-center gap-1 text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              <Palette size={14} />
              <span className="hidden sm:inline">色卡</span>
            </button>

            <button
              type="button"
              onClick={() => setTool(tool === 'connector' ? 'select' : 'connector')}
              title="连线箭头标注（依次点击两个节点或内部精确定位点）"
              aria-label="连线工具"
              className={[
                'charkle-pressable h-8 px-2 rounded-[var(--radius-dock-inner)] inline-flex items-center gap-1 cursor-pointer',
                tool === 'connector'
                  ? 'bg-[var(--accent)] text-white'
                  : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
              ].join(' ')}
            >
              <ArrowUpRight size={14} />
              <span className="hidden sm:inline">连线</span>
            </button>

            <button
              type="button"
              onClick={() => {
                if (isEditorial) {
                  switchBoardMode('freeform', stageWidth, assetsById);
                }
                setTool(tool === 'ink' ? 'select' : 'ink');
              }}
              title="自由画笔批注"
              aria-label="画笔工具"
              className={[
                'charkle-pressable h-8 px-2 rounded-[var(--radius-dock-inner)] inline-flex items-center gap-1 cursor-pointer',
                tool === 'ink'
                  ? 'bg-[var(--accent)] text-white'
                  : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
              ].join(' ')}
            >
              <PenTool size={14} />
              <span className="hidden sm:inline">画笔</span>
            </button>

            {tool === 'connector' && (
              <div className="flex items-center gap-1 pl-1 border-l border-[var(--border-hairline)]">
                {(['curved', 'elbow', 'straight'] as ConnectorStyle[]).map((st) => (
                  <button
                    key={st}
                    type="button"
                    onClick={() => setConnectorStyle(st)}
                    className={`px-1.5 h-6 rounded text-[11px] cursor-pointer ${
                      connectorStyle === st ? 'bg-[var(--accent-soft)] text-[var(--accent)]' : 'text-[var(--text-secondary)]'
                    }`}
                  >
                    {st === 'curved' ? '曲线' : st === 'elbow' ? '折线' : '直线'}
                  </button>
                ))}
                <button
                  type="button"
                  onClick={() => setConnectorDashed((v) => !v)}
                  className={`px-1.5 h-6 rounded text-[11px] cursor-pointer ${
                    connectorDashed ? 'bg-[var(--accent-soft)] text-[var(--accent)]' : 'text-[var(--text-secondary)]'
                  }`}
                >
                  虚线
                </button>
              </div>
            )}

            {tool === 'ink' && (
              <div className="flex items-center gap-1 pl-1.5 border-l border-[var(--border-hairline)]">
                {INK_COLORS.map((c) => (
                  <button
                    key={c}
                    type="button"
                    onClick={() => setInkColor(c)}
                    style={{ backgroundColor: c }}
                    className={`h-4 w-4 rounded-full border border-black/20 cursor-pointer ${
                      inkColor === c ? 'ring-2 ring-[var(--accent)]' : ''
                    }`}
                  />
                ))}
                <input
                  type="range"
                  min={1.5}
                  max={10}
                  step={0.5}
                  value={inkWidth}
                  onChange={(e) => setInkWidth(Number(e.target.value))}
                  className="w-12 accent-[var(--accent)]"
                />
              </div>
            )}

            {!isEditorial && (
              <div className="flex items-center gap-0.5 pl-1 border-l border-[var(--border-hairline)]">
                <button
                  type="button"
                  onClick={() => setZoom((z) => Math.max(0.25, Number((z - 0.15).toFixed(2))))}
                  aria-label="缩小画布"
                  className="h-7 w-7 rounded inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
                >
                  <ZoomOut size={13.5} />
                </button>
                <button
                  type="button"
                  onClick={() => {
                    setZoom(1);
                    setPan({ x: 0, y: 0 });
                  }}
                  className="px-1.5 text-[11px] text-[var(--text-secondary)] charkle-tabular cursor-pointer"
                >
                  {Math.round(zoom * 100)}%
                </button>
                <button
                  type="button"
                  onClick={() => setZoom((z) => Math.min(3, Number((z + 0.15).toFixed(2))))}
                  aria-label="放大画布"
                  className="h-7 w-7 rounded inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
                >
                  <ZoomIn size={13.5} />
                </button>
              </div>
            )}
          </div>
        </div>

        {/* Collapsible Right Candidate Replacement Pool */}
        {poolOpen && <CandidatePoolPanel />}
      </div>

      {/* Non-Destructive Crop Popover for Selected AssetRef */}
      {selectedNode && 'assetRef' in selectedNode.kind && (
        <Popover
          open={cropOpen}
          onOpenChange={setCropOpen}
          anchorEl={cropBtnRef.current}
          placement="bottom-center"
          className="w-[248px] p-3"
        >
          {(() => {
            const crop: NormalizedCropRect = selectedNode.kind.assetRef.crop ?? {
              x: 0,
              y: 0,
              width: 1,
              height: 1,
            };
            const updateCrop = (next: NormalizedCropRect | null) => {
              mutateActiveBoard((doc) => ({
                ...doc,
                nodes: doc.nodes.map((n) =>
                  n.id === selectedNode.id && 'assetRef' in n.kind
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
                <label className="flex items-center justify-between gap-2">
                  <span>缩放倍率</span>
                  <input
                    type="range"
                    min={0.35}
                    max={1}
                    step={0.05}
                    value={crop.width}
                    onChange={(e) => {
                      const w = Number(e.target.value);
                      updateCrop({
                        x: Math.min(1 - w, crop.x),
                        y: Math.min(1 - w, crop.y),
                        width: w,
                        height: w,
                      });
                    }}
                    className="w-28 accent-[var(--accent)]"
                  />
                </label>
                <label className="flex items-center justify-between gap-2">
                  <span>水平偏移</span>
                  <input
                    type="range"
                    min={0}
                    max={Math.max(0, 1 - crop.width)}
                    step={0.02}
                    value={crop.x}
                    onChange={(e) => updateCrop({ ...crop, x: Number(e.target.value) })}
                    className="w-28 accent-[var(--accent)]"
                  />
                </label>
                <label className="flex items-center justify-between gap-2">
                  <span>垂直偏移</span>
                  <input
                    type="range"
                    min={0}
                    max={Math.max(0, 1 - crop.height)}
                    step={0.02}
                    value={crop.y}
                    onChange={(e) => updateCrop({ ...crop, y: Number(e.target.value) })}
                    className="w-28 accent-[var(--accent)]"
                  />
                </label>
              </div>
            );
          })()}
        </Popover>
      )}

      {/* Export Popover (1x/2x PNG/JPG + Clipboard + Offline .charkleboard Figma Bridge) */}
      <Popover
        open={exportOpen}
        onOpenChange={setExportOpen}
        anchorEl={exportBtnRef.current}
        placement="bottom-end"
        className="w-[310px] p-3.5"
      >
        <div data-testid="moodboard-export-popover" className="flex flex-col gap-3 text-[12px]">
          <div className="text-[13px] font-semibold text-[var(--text-primary)]">
            导出情绪板与 Figma 桥接
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
              <span>附带顶部色卡条</span>
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
            <Button variant="secondary" size="sm" loading={exporting} onClick={() => void handleExportImage()} className="w-full justify-center">
              <ImageIcon size={14} />
              导出 {exportScale}× {exportFormat.toUpperCase()} 图片
            </Button>
            <Button variant="secondary" size="sm" loading={exporting} onClick={() => void handleCopyClipboard()} className="w-full justify-center">
              <Clipboard size={14} />
              复制高清图到剪贴板
            </Button>
            <Button variant="primary" size="sm" loading={exporting} onClick={() => void handleExportFigmaBridge()} className="w-full justify-center">
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
