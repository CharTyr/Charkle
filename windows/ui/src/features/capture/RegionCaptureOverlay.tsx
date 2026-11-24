import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Check, Folder, Inbox, LayoutGrid, X } from 'lucide-react';
import { getTransport } from '../../api/transport';
import { CustomSelect, type SelectOption } from '../../design-system';
import {
  buildFolderTree,
  flattenFolderTree,
  type CaptureSessionInfo,
  type FolderRecord,
  type MoodboardSummary,
  type ShelfTargetMode,
} from '../../types/domain';

interface SelectionBox {
  startX: number;
  startY: number;
  endX: number;
  endY: number;
}

export interface RegionCaptureOverlayProps {
  tokenOverride?: string;
}

/**
 * Fullscreen frameless multi-DPI Region Screenshot Capture overlay (`capture.html`):
 * - Displays frozen 1:1 physical-pixel desktop frame from `charkle-media://localhost/capture-frame/{token}`
 * - Renders precision crosshair, physical pixel dimensions badge, and 8x zoom pixel loupe
 * - Commits exact 1:1 physical crop directly into Inbox, Folder, or Active Moodboard
 */
export const RegionCaptureOverlay: React.FC<RegionCaptureOverlayProps> = ({ tokenOverride }) => {
  const token = useMemo(() => {
    if (tokenOverride) return tokenOverride;
    if (typeof window === 'undefined') return '';
    return new URLSearchParams(window.location.search).get('token') ?? '';
  }, [tokenOverride]);

  const transport = getTransport();
  const imgRef = useRef<HTMLImageElement | null>(null);
  const loupeCanvasRef = useRef<HTMLCanvasElement | null>(null);

  const [session, setSession] = useState<CaptureSessionInfo | null>(null);
  const [folders, setFolders] = useState<FolderRecord[]>([]);
  const [boards, setBoards] = useState<MoodboardSummary[]>([]);
  const [targetMode, setTargetMode] = useState<ShelfTargetMode>('inbox');
  const [selectedFolderId, setSelectedFolderId] = useState<string>('');
  const [cursor, setCursor] = useState({ x: 0, y: 0, visible: false });
  const [box, setBox] = useState<SelectionBox | null>(null);
  const [dragging, setDragging] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const commitLockRef = useRef(false);
  const cancelLockRef = useRef(false);

  useEffect(() => {
    if (!token) return;
    void Promise.all([
      transport.getCaptureSession(token),
      transport.fetchFolders(),
      transport.fetchBoards(),
    ]).then(([info, fList, bList]) => {
      setSession(info);
      setFolders(fList);
      setBoards(bList);
      if (info?.targetFolderId) {
        setTargetMode('folder');
        setSelectedFolderId(info.targetFolderId);
      } else if (info?.targetBoardId) {
        setTargetMode('activeMoodboard');
      } else if (fList[0]) {
        setSelectedFolderId(fList[0].id);
      }
    });
  }, [token, transport]);

  const normalized = useMemo(() => {
    if (!box) return null;
    const left = Math.min(box.startX, box.endX);
    const top = Math.min(box.startY, box.endY);
    const width = Math.abs(box.endX - box.startX);
    const height = Math.abs(box.endY - box.startY);
    return { left, top, width, height };
  }, [box]);

  const physicalCrop = useMemo(() => {
    if (!normalized) return null;
    const vw = Math.max(1, window.innerWidth || session?.width || 1920);
    const vh = Math.max(1, window.innerHeight || session?.height || 1080);
    const fw = Math.max(1, session?.width || vw);
    const fh = Math.max(1, session?.height || vh);
    const sx = fw / vw;
    const sy = fh / vh;
    const x = Math.max(0, Math.min(fw - 1, Math.round(normalized.left * sx)));
    const y = Math.max(0, Math.min(fh - 1, Math.round(normalized.top * sy)));
    const width = Math.max(1, Math.min(fw - x, Math.round(normalized.width * sx)));
    const height = Math.max(1, Math.min(fh - y, Math.round(normalized.height * sy)));
    return { x, y, width, height };
  }, [normalized, session]);

  const folderOptions = useMemo<SelectOption<string>[]>(() => {
    return flattenFolderTree(buildFolderTree(folders)).map((node) => ({
      value: node.folder.id,
      label: node.folder.name,
      depth: node.depth,
    }));
  }, [folders]);

  const handleCancel = useCallback(async () => {
    if (cancelLockRef.current || commitLockRef.current) return;
    cancelLockRef.current = true;
    try {
      if (token) {
        await transport.cancelRegionCapture(token);
      }
    } catch {
      cancelLockRef.current = false;
    }
  }, [token, transport]);

  const handleCommit = useCallback(async () => {
    if (!token || !physicalCrop || submitting || commitLockRef.current) return;
    if (physicalCrop.width < 4 || physicalCrop.height < 4) return;
    commitLockRef.current = true;
    setSubmitting(true);
    setErrorMessage(null);
    try {
      const folderId = targetMode === 'folder' && selectedFolderId ? selectedFolderId : null;
      const boardId =
        targetMode === 'activeMoodboard'
          ? (session?.targetBoardId ?? boards[0]?.id ?? null)
          : null;
      await transport.commitRegionCapture(
        token,
        physicalCrop.x,
        physicalCrop.y,
        physicalCrop.width,
        physicalCrop.height,
        folderId,
        boardId,
      );
    } catch (err) {
      commitLockRef.current = false;
      setErrorMessage(err instanceof Error && err.message ? err.message : '保存截图失败，请重试');
    } finally {
      setSubmitting(false);
    }
  }, [token, physicalCrop, submitting, targetMode, selectedFolderId, session?.targetBoardId, boards, transport]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        void handleCancel();
      } else if (e.key === 'Enter' && physicalCrop && physicalCrop.width >= 4 && physicalCrop.height >= 4) {
        e.preventDefault();
        void handleCommit();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [handleCancel, handleCommit, physicalCrop]);

  useEffect(() => {
    if (!dragging) return;
    const finishDrag = () => {
      setDragging(false);
      setBox((prev) => {
        if (!prev) return null;
        if (Math.abs(prev.endX - prev.startX) < 4 || Math.abs(prev.endY - prev.startY) < 4) {
          return null;
        }
        return prev;
      });
    };
    window.addEventListener('mouseup', finishDrag);
    window.addEventListener('blur', finishDrag);
    return () => {
      window.removeEventListener('mouseup', finishDrag);
      window.removeEventListener('blur', finishDrag);
    };
  }, [dragging]);

  // Render live 8x zoom pixel loupe near cursor
  useEffect(() => {
    const canvas = loupeCanvasRef.current;
    const img = imgRef.current;
    if (!canvas || !img || !cursor.visible || !img.complete || img.naturalWidth === 0) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const vw = Math.max(1, window.innerWidth || img.naturalWidth);
    const vh = Math.max(1, window.innerHeight || img.naturalHeight);
    const px = Math.round((cursor.x / vw) * img.naturalWidth);
    const py = Math.round((cursor.y / vh) * img.naturalHeight);

    const sampleSize = 15; // 15x15 source pixels zoomed 8x -> 120x120 loupe
    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    try {
      ctx.drawImage(
        img,
        px - Math.floor(sampleSize / 2),
        py - Math.floor(sampleSize / 2),
        sampleSize,
        sampleSize,
        0,
        0,
        canvas.width,
        canvas.height,
      );
    } catch {
      // Ignore synthetic canvas error in headless test environments
    }

    // Center pixel crosshair reticle
    ctx.strokeStyle = 'rgba(91, 141, 239, 0.95)';
    ctx.lineWidth = 1.5;
    const mid = canvas.width / 2;
    ctx.strokeRect(mid - 4, mid - 4, 8, 8);
  }, [cursor]);

  const frameUrl = token ? transport.captureFrameUrl(token) : '';
  const hasActiveSelection = Boolean(normalized && normalized.width >= 4 && normalized.height >= 4);
  const vw = window.innerWidth || 1920;
  const vh = window.innerHeight || 1080;
  const loupeLeft = cursor.x + 20 + 132 > vw ? Math.max(12, cursor.x - 144) : cursor.x + 20;
  const loupeTop = cursor.y + 20 + 156 > vh ? Math.max(12, cursor.y - 168) : cursor.y + 20;

  return (
    <div
      data-testid="region-capture-overlay"
      onContextMenu={(e) => {
        e.preventDefault();
        void handleCancel();
      }}
      onMouseDown={(e) => {
        if (e.button !== 0) return;
        if (!e.currentTarget.contains(e.target as Node)) return;
        if ((e.target as HTMLElement).closest('[data-capture-toolbar="true"]')) return;
        setErrorMessage(null);
        setDragging(true);
        setBox({
          startX: e.clientX,
          startY: e.clientY,
          endX: e.clientX,
          endY: e.clientY,
        });
      }}
      onMouseMove={(e) => {
        setCursor({ x: e.clientX, y: e.clientY, visible: true });
        if (dragging) {
          setBox((prev) => (prev ? { ...prev, endX: e.clientX, endY: e.clientY } : null));
        }
      }}
      onMouseUp={() => {
        setDragging(false);
        setBox((prev) => {
          if (!prev) return null;
          if (Math.abs(prev.endX - prev.startX) < 4 || Math.abs(prev.endY - prev.startY) < 4) {
            return null;
          }
          return prev;
        });
      }}
      className="relative w-screen h-screen overflow-hidden select-none cursor-crosshair bg-[#0b0c0f]"
    >
      {/* Frozen 1:1 physical desktop frame */}
      {frameUrl && (
        <img
          ref={imgRef}
          src={frameUrl}
          alt="Frozen Desktop"
          draggable={false}
          className="w-full h-full object-fill pointer-events-none"
        />
      )}

      {/* Calm dim overlay only before selection begins; active selection dims exclusively outside via box-shadow */}
      {!hasActiveSelection && (
        <div className="pointer-events-none absolute inset-0 bg-black/38" />
      )}

      {/* Inline error feedback if screenshot commit fails */}
      {errorMessage && (
        <div
          role="alert"
          className="pointer-events-none charkle-glass-dark absolute top-6 left-1/2 -translate-x-1/2 z-40 rounded-full px-3.5 py-1.5 text-[12px] text-rose-300 border border-rose-400/35 whitespace-nowrap"
        >
          {errorMessage}
        </div>
      )}

      {/* Minimal top-center hint before dragging begins */}
      {!hasActiveSelection && !errorMessage && (
        <div className="pointer-events-none charkle-glass-dark absolute top-6 left-1/2 -translate-x-1/2 z-30 rounded-full px-3.5 py-1.5 text-[12px] text-white/90 whitespace-nowrap">
          拖拽框选截图区域 · 右键或 Esc 取消
        </div>
      )}

      {/* Precision Crosshair Guides */}
      {cursor.visible && !hasActiveSelection && (
        <>
          <div
            aria-hidden="true"
            className="pointer-events-none absolute inset-x-0 h-px bg-white/35"
            style={{ top: cursor.y }}
          />
          <div
            aria-hidden="true"
            className="pointer-events-none absolute inset-y-0 w-px bg-white/35"
            style={{ left: cursor.x }}
          />
        </>
      )}

      {/* Active Crop Selection Rectangle */}
      {hasActiveSelection && normalized && (
        <div
          data-testid="capture-selection-rect"
          style={{
            left: normalized.left,
            top: normalized.top,
            width: normalized.width,
            height: normalized.height,
          }}
          className="pointer-events-none absolute border-2 border-[#5B8DEF] shadow-[0_0_0_9999px_rgba(0,0,0,0.42)]"
        >
          {physicalCrop && (
            <div
              data-testid="capture-size-badge"
              className={[
                'charkle-glass-dark absolute px-2 py-0.5 rounded-[6px] text-[11.5px] font-medium charkle-tabular whitespace-nowrap',
                normalized.top < 32 ? 'top-1.5 left-1.5' : '-top-7 left-0',
              ].join(' ')}
            >
              {physicalCrop.width} × {physicalCrop.height} px
            </div>
          )}
        </div>
      )}

      {/* 8x Zoom Pixel Loupe */}
      {cursor.visible && (
        <div
          aria-hidden="true"
          style={{ left: Math.max(12, loupeLeft), top: Math.max(12, loupeTop) }}
          className="pointer-events-none absolute z-30 rounded-[12px] overflow-hidden border border-white/25 bg-[#0b0c0f] shadow-2xl"
        >
          <canvas
            ref={loupeCanvasRef}
            width={120}
            height={120}
            data-testid="capture-loupe-canvas"
            className="block"
          />
          <div className="px-2 py-1 text-[10.5px] text-white/80 flex items-center justify-between charkle-tabular bg-black/80">
            <span>8× 放大</span>
            <span>
              {Math.round(cursor.x)}, {Math.round(cursor.y)}
            </span>
          </div>
        </div>
      )}

      {/* Floating Target & Confirm Toolbar */}
      <div
        data-capture-toolbar="true"
        className="charkle-glass-dark absolute bottom-6 left-1/2 -translate-x-1/2 z-40 rounded-full px-3 py-1.5 flex items-center gap-2 text-[12px]"
      >
        <div className="inline-flex items-center gap-1 bg-white/8 rounded-full p-0.5">
          {(
            [
              { id: 'inbox', label: '收件箱', icon: <Inbox size={11.5} /> },
              { id: 'folder', label: folders.find((f) => f.id === selectedFolderId)?.name ?? '文件夹', icon: <Folder size={11.5} /> },
              { id: 'activeMoodboard', label: '情绪板', icon: <LayoutGrid size={11.5} /> },
            ] as const
          ).map((opt) => (
            <button
              key={opt.id}
              type="button"
              onClick={() => {
                setTargetMode(opt.id);
                if (opt.id === 'folder' && !selectedFolderId && folders[0]) {
                  setSelectedFolderId(folders[0].id);
                }
              }}
              className={[
                'charkle-pressable h-6 px-2 rounded-full inline-flex items-center gap-1 cursor-pointer text-[11.5px]',
                targetMode === opt.id ? 'bg-[#5B8DEF] text-white font-medium' : 'text-white/75 hover:text-white',
              ].join(' ')}
            >
              {opt.icon}
              <span className="max-w-[96px] truncate">{opt.label}</span>
            </button>
          ))}
        </div>

        {targetMode === 'folder' && folderOptions.length > 1 && (
          <CustomSelect<string>
            value={selectedFolderId}
            options={folderOptions}
            onChange={(fid) => setSelectedFolderId(fid)}
            ariaLabel="选择截图目标文件夹"
            size="xs"
            className="h-6 max-w-[132px] bg-white/12 border-white/15 text-white text-[11px]"
          />
        )}

        <button
          type="button"
          disabled={!physicalCrop || physicalCrop.width < 4 || physicalCrop.height < 4 || submitting}
          onClick={() => void handleCommit()}
          className="charkle-pressable h-7 px-3 rounded-full bg-[#5B8DEF] hover:bg-[#74A0F7] disabled:opacity-40 text-white font-medium inline-flex items-center gap-1 cursor-pointer"
        >
          <Check size={13.5} />
          <span>保存截图 (Enter)</span>
        </button>

        <button
          type="button"
          onClick={() => void handleCancel()}
          className="charkle-pressable h-7 px-2.5 rounded-full bg-white/10 hover:bg-white/20 text-white/85 inline-flex items-center gap-1 cursor-pointer"
        >
          <X size={13.5} />
          <span>取消 (Esc)</span>
        </button>
      </div>
    </div>
  );
};
