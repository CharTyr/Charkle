import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Camera,
  Check,
  Clipboard,
  Expand,
  FileText,
  Folder,
  Globe,
  Grid2x2,
  Link2,
  Loader2,
  Palette,
  Pin,
  Search,
  Upload,
  X,
} from 'lucide-react';
import { isLightHex } from '@charkle/shared';
import type { AssetRecord, CaptureInput, UUID } from '@charkle/shared';
import { thumbnailURL } from '../../api/client';
import { CharkleIcon } from '../../design-system/CharkleIcon';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import type { QuickDropTarget } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import {
  captureScreenFrame,
  detectURLFromText,
  fileToBase64,
  isEditableElement,
  normalizeHexInput,
  textToCaptureInput,
} from './captureUtils';

type CaptureTab = 'drop' | 'url' | 'text' | 'color' | 'screen';

const CAPTURE_TABS: ReadonlyArray<{ id: CaptureTab; label: string; icon: React.ReactNode }> = [
  { id: 'drop', label: '拖入文件', icon: <Upload size={12} /> },
  { id: 'url', label: '粘贴链接', icon: <Link2 size={12} /> },
  { id: 'text', label: '文本片段', icon: <FileText size={12} /> },
  { id: 'color', label: '色卡', icon: <Palette size={12} /> },
  { id: 'screen', label: '屏幕截屏', icon: <Camera size={12} /> },
];

export const QuickDropShelf: React.FC = () => {
  const enabled = useCoordinatorStore((s) => s.quickDropShelfEnabled);
  const open = useCoordinatorStore((s) => s.quickDropShelfOpen);
  const fullExpanded = useCoordinatorStore((s) => s.quickDropShelfExpanded);
  const pinned = useCoordinatorStore((s) => s.quickDropShelfPinned);
  const target = useCoordinatorStore((s) => s.quickDropTarget);
  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
  const destination = useCoordinatorStore((s) => s.destination);

  const setOpen = useCoordinatorStore((s) => s.setQuickDropShelfOpen);
  const setFullExpanded = useCoordinatorStore((s) => s.setQuickDropShelfExpanded);
  const setPinned = useCoordinatorStore((s) => s.setQuickDropShelfPinned);
  const setTarget = useCoordinatorStore((s) => s.setQuickDropTarget);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const folders = useLibraryStore((s) => s.folders);
  const recentActivityAssets = useLibraryStore((s) => s.recentActivityAssets);
  const cacheBustVersion = useLibraryStore((s) => s.cacheBustVersion);
  const ingestInputs = useLibraryStore((s) => s.ingestInputs);
  const uploadFiles = useLibraryStore((s) => s.uploadFiles);
  const loadRecentActivity = useLibraryStore((s) => s.loadRecentActivity);
  const markOpened = useLibraryStore((s) => s.markOpened);

  const boards = useMoodboardStore((s) => s.boards);

  const [activeTab, setActiveTab] = useState<CaptureTab>('drop');
  const [urlInput, setUrlInput] = useState('');
  const [textTitle, setTextTitle] = useState('');
  const [textBody, setTextBody] = useState('');
  const [colorHex, setColorHex] = useState('#3D5A80');
  const [colorTitle, setColorTitle] = useState('');
  const [waterfallQuery, setWaterfallQuery] = useState('');

  const [isDraggingOverWindow, setIsDraggingOverWindow] = useState(false);
  const [isDraggingOverWell, setIsDraggingOverWell] = useState(false);
  const [processing, setProcessing] = useState(false);
  const [confirmMessage, setConfirmMessage] = useState<string | null>(null);
  const [clipboardHintURL, setClipboardHintURL] = useState<{ url: string; badge: string } | null>(null);

  const dragDepthRef = useRef(0);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const confirmTimerRef = useRef<number | null>(null);

  const activeBoard = useMemo(
    () => boards.find((b) => b.id === activeBoardID) ?? boards[0] ?? null,
    [boards, activeBoardID],
  );

  const selectedFolderID = target.type === 'folder' ? target.folderID : folders[0]?.id ?? null;

  const resolveDestinationOpts = useCallback((): {
    targetFolderID: UUID | null;
    targetBoardID: UUID | null;
    label: string;
  } => {
    if (target.type === 'folder') {
      const f = folders.find((item) => item.id === target.folderID) ?? folders[0];
      return {
        targetFolderID: f?.id ?? null,
        targetBoardID: null,
        label: f ? `文件夹「${f.name}」` : '收件箱',
      };
    }
    if (target.type === 'activeMoodboard' && activeBoard) {
      return {
        targetFolderID: null,
        targetBoardID: activeBoard.id,
        label: `情绪板「${activeBoard.title}」`,
      };
    }
    return { targetFolderID: null, targetBoardID: null, label: '收件箱' };
  }, [target, folders, activeBoard]);

  const flashConfirmation = useCallback(
    (msg: string) => {
      setConfirmMessage(msg);
      if (confirmTimerRef.current !== null) {
        window.clearTimeout(confirmTimerRef.current);
      }
      confirmTimerRef.current = window.setTimeout(() => {
        setConfirmMessage(null);
        confirmTimerRef.current = null;
      }, 2200);
      pushToast({ tone: 'success', message: msg });
    },
    [pushToast],
  );

  const performFileIngest = useCallback(
    async (files: File[]) => {
      if (files.length === 0) return;
      setProcessing(true);
      try {
        const dest = resolveDestinationOpts();
        const created = await uploadFiles(files, {
          targetFolderID: dest.targetFolderID,
          targetBoardID: dest.targetBoardID,
        });
        flashConfirmation(`已采集 ${created.length} 个文件至${dest.label}`);
      } catch (err) {
        pushToast({
          tone: 'error',
          message: err instanceof Error ? err.message : '采集文件失败',
        });
      } finally {
        setProcessing(false);
      }
    },
    [resolveDestinationOpts, uploadFiles, flashConfirmation, pushToast],
  );

  const performInputsIngest = useCallback(
    async (inputs: CaptureInput[], customSummary?: string) => {
      if (inputs.length === 0) return;
      setProcessing(true);
      try {
        const dest = resolveDestinationOpts();
        const created = await ingestInputs(inputs, {
          targetFolderID: dest.targetFolderID,
          targetBoardID: dest.targetBoardID,
        });
        flashConfirmation(customSummary ?? `已采集 ${created.length} 项灵感至${dest.label}`);
      } catch (err) {
        pushToast({
          tone: 'error',
          message: err instanceof Error ? err.message : '采集失败',
        });
      } finally {
        setProcessing(false);
      }
    },
    [resolveDestinationOpts, ingestInputs, flashConfirmation, pushToast],
  );

  // Refresh recent activity whenever shelf opens
  useEffect(() => {
    if (open) {
      void loadRecentActivity(24);
      // Quietly peek clipboard for social/GitHub URL hint if permitted
      if (navigator.clipboard?.readText) {
        navigator.clipboard
          .readText()
          .then((txt) => {
            const info = detectURLFromText(txt);
            if (info && info.kind !== 'web') {
              setClipboardHintURL({ url: info.url, badge: info.badge });
            } else {
              setClipboardHintURL(null);
            }
          })
          .catch(() => {
            // Clipboard permission not granted yet — totally normal
          });
      }
    }
  }, [open, loadRecentActivity]);

  // Global drag-and-drop auto-expansion when dragging external files or URLs over window
  useEffect(() => {
    if (!enabled) return;

    const isExternalPayload = (dt: DataTransfer | null): boolean => {
      if (!dt) return false;
      const types = Array.from(dt.types);
      // Do not hijack internal drag-and-drop of library cards or folders
      if (types.includes('application/x-charkle-asset-ids') || types.includes('application/x-charkle-folder-id')) {
        return false;
      }
      return types.includes('Files') || types.includes('text/uri-list');
    };

    const onDragEnter = (e: DragEvent) => {
      if (!isExternalPayload(e.dataTransfer)) return;
      // If user is directly dropping onto the Moodboard Canvas, let the canvas handle exact world-coordinate drop unless hovering top 140px
      if (destination.type === 'moodboard' && e.clientY > 140 && !open) return;
      dragDepthRef.current += 1;
      setIsDraggingOverWindow(true);
      setOpen(true);
      setActiveTab('drop');
    };

    const onDragOver = (e: DragEvent) => {
      if (!isExternalPayload(e.dataTransfer)) return;
      if (e.clientY <= 140 && !open) {
        setIsDraggingOverWindow(true);
        setOpen(true);
      }
    };

    const onDragLeave = () => {
      dragDepthRef.current = Math.max(0, dragDepthRef.current - 1);
      if (dragDepthRef.current === 0) {
        setIsDraggingOverWindow(false);
        setIsDraggingOverWell(false);
      }
    };

    const onDrop = () => {
      dragDepthRef.current = 0;
      setIsDraggingOverWindow(false);
      setIsDraggingOverWell(false);
    };

    window.addEventListener('dragenter', onDragEnter);
    window.addEventListener('dragover', onDragOver);
    window.addEventListener('dragleave', onDragLeave);
    window.addEventListener('drop', onDrop);
    return () => {
      window.removeEventListener('dragenter', onDragEnter);
      window.removeEventListener('dragover', onDragOver);
      window.removeEventListener('dragleave', onDragLeave);
      window.removeEventListener('drop', onDrop);
    };
  }, [enabled, destination.type, open, setOpen]);

  // Global Cmd/Ctrl+V clipboard paste capture (only when NOT typing in inputs!)
  useEffect(() => {
    if (!enabled) return;

    const onPaste = async (e: ClipboardEvent) => {
      if (isEditableElement(e.target)) return;
      const dt = e.clipboardData;
      if (!dt) return;

      const files = Array.from(dt.files);
      if (files.length > 0) {
        e.preventDefault();
        setOpen(true);
        await performFileIngest(files);
        return;
      }

      // Check clipboard items for raw image blob
      for (const item of Array.from(dt.items)) {
        if (item.kind === 'file' && item.type.startsWith('image/')) {
          const blob = item.getAsFile();
          if (blob) {
            e.preventDefault();
            setOpen(true);
            const b64 = await fileToBase64(blob);
            const ext = blob.type.split('/')[1] || 'png';
            await performInputsIngest([
              {
                type: 'imageData',
                base64Data: b64,
                suggestedName: `clipboard-${Date.now()}.${ext}`,
              },
            ]);
            return;
          }
        }
      }

      const text = dt.getData('text/plain');
      if (text && text.trim().length > 0) {
        const input = textToCaptureInput(text);
        if (input) {
          e.preventDefault();
          setOpen(true);
          const urlInfo = detectURLFromText(text);
          const summary = urlInfo
            ? `已采集${urlInfo.badge}至${resolveDestinationOpts().label}`
            : input.type === 'colorSwatch'
              ? `已采集色卡 ${input.hex} 至${resolveDestinationOpts().label}`
              : undefined;
          await performInputsIngest([input], summary);
        }
      }
    };

    window.addEventListener('paste', onPaste);
    return () => window.removeEventListener('paste', onPaste);
  }, [enabled, setOpen, performFileIngest, performInputsIngest, resolveDestinationOpts]);

  // Close with Esc when open & not pinned
  useEffect(() => {
    if (!open) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !pinned) {
        setFullExpanded(false);
        setOpen(false);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [open, pinned, setOpen, setFullExpanded]);

  const handleWellDrop = async (e: React.DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setIsDraggingOverWell(false);
    setIsDraggingOverWindow(false);
    dragDepthRef.current = 0;

    const files = Array.from(e.dataTransfer.files);
    if (files.length > 0) {
      await performFileIngest(files);
      return;
    }

    const uri = e.dataTransfer.getData('text/uri-list') || e.dataTransfer.getData('text/plain');
    if (uri) {
      const input = textToCaptureInput(uri);
      if (input) {
        await performInputsIngest([input]);
      }
    }
  };

  const handleManualClipboardRead = async () => {
    try {
      if (navigator.clipboard?.read) {
        const items = await navigator.clipboard.read();
        for (const item of items) {
          const imgType = item.types.find((t) => t.startsWith('image/'));
          if (imgType) {
            const blob = await item.getType(imgType);
            const b64 = await fileToBase64(blob);
            await performInputsIngest([
              {
                type: 'imageData',
                base64Data: b64,
                suggestedName: `clipboard-${Date.now()}.${imgType.split('/')[1] || 'png'}`,
              },
            ]);
            return;
          }
        }
      }
      if (navigator.clipboard?.readText) {
        const text = await navigator.clipboard.readText();
        const input = textToCaptureInput(text);
        if (input) {
          await performInputsIngest([input]);
          return;
        }
      }
      pushToast({ tone: 'info', message: '剪贴板为空，请直接按 ⌘V 粘贴图片、链接或色值' });
    } catch {
      pushToast({ tone: 'info', message: '请直接使用 ⌘V 粘贴（浏览器限制主动读取剪贴板）' });
    }
  };

  const handleScreenCapture = async () => {
    setProcessing(true);
    try {
      const input = await captureScreenFrame();
      await performInputsIngest([input], `已截取屏幕画面并存入${resolveDestinationOpts().label}`);
    } catch (err) {
      setProcessing(false);
      if ((err as Error)?.name !== 'NotAllowedError') {
        pushToast({
          tone: 'error',
          message: err instanceof Error ? err.message : '屏幕截屏失败',
        });
      }
    }
  };

  const detectedURL = useMemo(() => detectURLFromText(urlInput), [urlInput]);

  const filteredRecentAssets = useMemo(() => {
    const q = waterfallQuery.trim().toLowerCase();
    if (!q) return recentActivityAssets;
    return recentActivityAssets.filter(
      (a) =>
        a.title.toLowerCase().includes(q) ||
        a.tags.some((t) => t.toLowerCase().includes(q)) ||
        (a.sourceDomain?.toLowerCase().includes(q) ?? false),
    );
  }, [recentActivityAssets, waterfallQuery]);

  if (!enabled) return null;

  const targetIndex = target.type === 'inbox' ? 0 : target.type === 'folder' ? 1 : 2;

  const handleSelectTarget = (nextType: QuickDropTarget['type']) => {
    if (nextType === 'inbox') {
      setTarget({ type: 'inbox' });
    } else if (nextType === 'folder') {
      const fid = selectedFolderID ?? folders[0]?.id;
      if (fid) setTarget({ type: 'folder', folderID: fid });
      else pushToast({ tone: 'info', message: '请先在左侧创建一个文件夹' });
    } else {
      if (activeBoard) setTarget({ type: 'activeMoodboard' });
      else pushToast({ tone: 'info', message: '请先创建或打开一块情绪板' });
    }
  };

  return (
    <div className="fixed top-0 left-1/2 -translate-x-1/2 z-[90] flex flex-col items-center pointer-events-none">
      {/* Hidden native file picker */}
      <input
        ref={fileInputRef}
        type="file"
        multiple
        className="hidden"
        onChange={(e) => {
          const files = Array.from(e.target.files ?? []);
          e.target.value = '';
          if (files.length > 0) void performFileIngest(files);
        }}
      />

      {/* Collapsed Flush MacBook Notch Pill vs Spring-Morphing Dark Glass Shelf */}
      {!open ? (
        <button
          type="button"
          onClick={() => setOpen(true)}
          aria-label="展开快速采集浮窗 (Quick Drop Shelf)"
          title="点击展开快速采集浮窗，或直接拖入文件 / 按 ⌘V 粘贴"
          className={[
            'pointer-events-auto charkle-glass-dark charkle-pressable mt-0',
            'h-[22px] px-3.5 rounded-t-none rounded-b-[12px] inline-flex items-center gap-1.5 cursor-pointer',
            'transition-[transform,opacity] duration-[220ms] [@media(hover:hover)_and_(pointer:fine)]:hover:scale-[1.03]',
            confirmMessage ? 'ring-2 ring-[#34C769]/70' : '',
          ].join(' ')}
          style={{
            transformOrigin: 'top center',
            transitionTimingFunction: 'var(--ease-spring)',
          }}
        >
          <CharkleIcon name="notch" size={12} tintHex="#FFFFFF" />
          <span className="text-[11px] font-medium text-white/90 tracking-tight leading-none">
            {confirmMessage ?? '快速采集'}
          </span>
          <span
            className="w-1.5 h-1.5 rounded-full"
            style={{
              backgroundColor: confirmMessage
                ? '#34C769'
                : target.type === 'activeMoodboard' && activeBoard
                  ? '#34C769'
                  : '#5B8DEF',
            }}
          />
        </button>
      ) : (
        <section
          aria-label="Charkle 快速采集托盘"
          className={[
            'pointer-events-auto charkle-glass-dark mt-0 rounded-t-none rounded-b-[22px] overflow-hidden text-[#F4F5F7]',
            'transition-[transform,opacity] duration-[280ms]',
            fullExpanded ? 'w-[min(92vw,760px)]' : 'w-[min(92vw,580px)]',
          ].join(' ')}
          style={{
            transformOrigin: 'top center',
            transitionTimingFunction: 'var(--ease-spring)',
            boxShadow: confirmMessage
              ? '0 0 0 1.5px rgba(52, 199, 105, 0.72), 0 18px 46px rgba(0, 0, 0, 0.5)'
              : isDraggingOverWindow || isDraggingOverWell
                ? '0 0 0 1.5px rgba(59, 130, 246, 0.85), 0 18px 46px rgba(0, 0, 0, 0.5)'
                : undefined,
          }}
        >
          {/* Band 1: Top Wing Bar */}
          <div className="h-10 px-4 border-b border-white/10 flex items-center justify-between gap-2">
            <div className="flex items-center gap-2 min-w-0">
              <CharkleIcon name="notch" size={16} tintHex="#FFFFFF" />
              <span className="text-[12.5px] font-semibold text-white/95">Charkle 快速采集</span>
              <span className="text-[10.5px] text-white/45 hidden sm:inline">
                拖入文件或随时 ⌘V 粘贴
              </span>
            </div>

            <div className="flex items-center gap-1.5 shrink-0">
              <button
                type="button"
                onClick={() => void handleManualClipboardRead()}
                title="从剪贴板采集 (⌘V)"
                className="charkle-pressable inline-flex items-center gap-1 px-2 py-1 rounded-full bg-white/8 hover:bg-white/14 text-[11px] text-white/85 cursor-pointer"
              >
                <Clipboard size={11} />
                剪贴板
              </button>

              <button
                type="button"
                onClick={() => setFullExpanded(!fullExpanded)}
                title={fullExpanded ? '收起为紧凑模式' : '展开全部最近素材瀑布流'}
                className={[
                  'charkle-pressable w-6 h-6 rounded-full inline-flex items-center justify-center cursor-pointer',
                  fullExpanded ? 'bg-[#3B82F6] text-white' : 'bg-white/8 text-white/75 hover:bg-white/14',
                ].join(' ')}
              >
                <Grid2x2 size={11} />
              </button>

              <button
                type="button"
                onClick={() => setPinned(!pinned)}
                title={pinned ? '取消固定展开' : '固定展开托盘'}
                className={[
                  'charkle-pressable w-6 h-6 rounded-full inline-flex items-center justify-center cursor-pointer',
                  pinned ? 'bg-[#3B82F6]/25 text-[#60A5FA]' : 'bg-white/8 text-white/70 hover:bg-white/14',
                ].join(' ')}
              >
                <Pin size={11} />
              </button>

              <button
                type="button"
                onClick={() => {
                  setFullExpanded(false);
                  setOpen(false);
                }}
                aria-label="收起快速采集托盘"
                className="charkle-pressable w-6 h-6 rounded-full bg-white/8 hover:bg-white/16 text-white/75 inline-flex items-center justify-center cursor-pointer"
              >
                <X size={12} />
              </button>
            </div>
          </div>

          {/* Band 2: Target Selector Row */}
          <div className="px-4 py-2.5 border-b border-white/8 flex flex-wrap items-center justify-between gap-2">
            {/* 3-Way Destination Segmented Pill */}
            <div className="relative inline-grid grid-cols-3 p-0.5 rounded-[10px] bg-white/8">
              <span
                aria-hidden="true"
                className="absolute top-0.5 bottom-0.5 left-0.5 w-[calc(33.333%-2px)] rounded-[8px] bg-white/18 transition-transform duration-[240ms]"
                style={{
                  transitionTimingFunction: 'var(--ease-in-out)',
                  transform: `translateX(${targetIndex * 100}%)`,
                }}
              />
              {(
                [
                  { id: 'inbox', label: '收件箱' },
                  { id: 'folder', label: '指定文件夹' },
                  { id: 'activeMoodboard', label: '活跃情绪板' },
                ] as const
              ).map((seg) => (
                <button
                  key={seg.id}
                  type="button"
                  onClick={() => handleSelectTarget(seg.id)}
                  className={[
                    'relative z-10 px-2.5 py-1 text-[11px] font-medium cursor-pointer whitespace-nowrap',
                    target.type === seg.id ? 'text-white' : 'text-white/60 hover:text-white/85',
                  ].join(' ')}
                >
                  {seg.label}
                </button>
              ))}
            </div>

            {/* Secondary destination detail chip */}
            <div className="flex items-center gap-1.5 text-[11px]">
              {target.type === 'folder' && folders.length > 0 && (
                <div className="inline-flex items-center gap-1 px-2 py-1 rounded-[8px] bg-white/8 border border-white/10">
                  <Folder size={11} className="text-white/70" />
                  <select
                    aria-label="选择目标文件夹"
                    value={selectedFolderID ?? ''}
                    onChange={(e) => setTarget({ type: 'folder', folderID: e.target.value })}
                    className="bg-transparent text-white/90 text-[11px] outline-none cursor-pointer max-w-[140px]"
                  >
                    {folders.map((f) => (
                      <option key={f.id} value={f.id} className="bg-[#18191C] text-white">
                        {f.name}
                      </option>
                    ))}
                  </select>
                </div>
              )}

              {target.type === 'activeMoodboard' && (
                <div className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-[8px] bg-white/8 border border-white/10 text-white/88 max-w-[180px]">
                  <span className="w-2 h-2 rounded-full bg-[#34C769] shrink-0" />
                  <span className="truncate">{activeBoard?.title ?? '未选择情绪板'}</span>
                </div>
              )}
            </div>
          </div>

          {!fullExpanded ? (
            <div className="p-4 flex flex-col gap-3">
              {/* Compact Inline Quick-Capture Mode Tabs */}
              <div className="flex items-center gap-1 overflow-x-auto charkle-scroll">
                {CAPTURE_TABS.map((t) => {
                  const active = activeTab === t.id;
                  return (
                    <button
                      key={t.id}
                      type="button"
                      onClick={() => setActiveTab(t.id)}
                      className={[
                        'charkle-pressable inline-flex items-center gap-1.5 px-2.5 py-1 rounded-[8px] text-[11.5px] font-medium shrink-0 cursor-pointer',
                        active
                          ? 'bg-white/16 text-white'
                          : 'text-white/60 hover:text-white/90 hover:bg-white/6',
                      ].join(' ')}
                    >
                      {t.icon}
                      {t.label}
                    </button>
                  );
                })}
              </div>

              {/* Active Capture Surface */}
              {activeTab === 'drop' && (
                <div
                  onDragOver={(e) => {
                    e.preventDefault();
                    setIsDraggingOverWell(true);
                  }}
                  onDragLeave={() => setIsDraggingOverWell(false)}
                  onDrop={(e) => void handleWellDrop(e)}
                  onClick={() => fileInputRef.current?.click()}
                  className={[
                    'min-h-[68px] px-4 py-3 rounded-[14px] border border-dashed flex items-center justify-between gap-3 cursor-pointer transition-colors duration-150',
                    confirmMessage
                      ? 'bg-[#34C769]/16 border-[#34C769]/70 text-[#86EFAC]'
                      : isDraggingOverWell || isDraggingOverWindow
                        ? 'bg-[#3B82F6]/20 border-[#3B82F6] text-white'
                        : 'bg-white/[0.04] border-white/18 hover:border-white/35 text-white/80',
                  ].join(' ')}
                >
                  {processing ? (
                    <div className="flex items-center gap-2 text-[12px] text-white">
                      <Loader2 size={15} className="animate-spin text-[#60A5FA]" />
                      正在解析与生成缩略图…
                    </div>
                  ) : confirmMessage ? (
                    <div className="flex items-center gap-2 text-[12.5px] font-medium">
                      <Check size={15} />
                      {confirmMessage}
                    </div>
                  ) : clipboardHintURL && !isDraggingOverWell ? (
                    <div className="flex items-center justify-between gap-3 w-full">
                      <div className="min-w-0 flex items-center gap-2">
                        <Globe size={14} className="text-[#60A5FA] shrink-0" />
                        <div className="min-w-0">
                          <div className="text-[11.5px] font-medium text-white truncate">
                            检测到剪贴板 {clipboardHintURL.badge}
                          </div>
                          <div className="text-[10.5px] text-white/50 truncate">
                            {clipboardHintURL.url}
                          </div>
                        </div>
                      </div>
                      <button
                        type="button"
                        onClick={(e) => {
                          e.stopPropagation();
                          void performInputsIngest(
                            [{ type: 'webURL', url: clipboardHintURL.url }],
                            `已一键采集${clipboardHintURL.badge}`,
                          );
                          setClipboardHintURL(null);
                        }}
                        className="charkle-pressable px-2.5 py-1 rounded-[8px] bg-[#3B82F6] text-white text-[11px] font-medium shrink-0 cursor-pointer"
                      >
                        一键收藏
                      </button>
                    </div>
                  ) : (
                    <>
                      <div className="flex items-center gap-2.5 text-[12px]">
                        <Upload size={15} className="text-white/60 shrink-0" />
                        <span>
                          {isDraggingOverWell || isDraggingOverWindow
                            ? `松开即可存入${resolveDestinationOpts().label}`
                            : '拖入图片、视频、音频、3D 模型或点击选择文件'}
                        </span>
                      </div>
                      <span className="text-[10.5px] px-2 py-0.5 rounded bg-white/8 text-white/55 shrink-0">
                        支持 ⌘V
                      </span>
                    </>
                  )}
                </div>
              )}

              {activeTab === 'url' && (
                <form
                  onSubmit={(e) => {
                    e.preventDefault();
                    if (!urlInput.trim()) return;
                    const input = textToCaptureInput(urlInput);
                    if (input) {
                      setUrlInput('');
                      void performInputsIngest([input]);
                    }
                  }}
                  className="flex items-center gap-2"
                >
                  <div className="relative flex-1 flex items-center">
                    <input
                      type="url"
                      value={urlInput}
                      onChange={(e) => setUrlInput(e.target.value)}
                      placeholder="粘贴 X / Threads / Bluesky / GitHub 或任意网页链接…"
                      className="w-full h-9 pl-3 pr-24 rounded-[10px] bg-white/8 border border-white/14 text-[12px] text-white placeholder:text-white/40 outline-none focus:border-[#3B82F6]"
                    />
                    {detectedURL && (
                      <span className="absolute right-2 px-1.5 py-0.5 rounded-[6px] bg-[#3B82F6]/25 text-[#93C5FD] text-[10px] font-medium">
                        {detectedURL.badge}
                      </span>
                    )}
                  </div>
                  <button
                    type="submit"
                    disabled={processing || !urlInput.trim()}
                    className="charkle-pressable h-9 px-3.5 rounded-[10px] bg-[#3B82F6] hover:bg-[#2563EB] disabled:opacity-40 text-white text-[12px] font-medium cursor-pointer shrink-0"
                  >
                    采集
                  </button>
                </form>
              )}

              {activeTab === 'text' && (
                <form
                  onSubmit={(e) => {
                    e.preventDefault();
                    if (!textBody.trim()) return;
                    const payload: CaptureInput = {
                      type: 'textSnippet',
                      title: textTitle.trim() || textBody.trim().slice(0, 36),
                      text: textBody.trim(),
                    };
                    setTextTitle('');
                    setTextBody('');
                    void performInputsIngest([payload]);
                  }}
                  className="flex flex-col gap-2"
                >
                  <div className="flex items-center gap-2">
                    <input
                      type="text"
                      value={textTitle}
                      onChange={(e) => setTextTitle(e.target.value)}
                      placeholder="片段标题（可选）"
                      className="flex-1 h-8 px-2.5 rounded-[8px] bg-white/8 border border-white/12 text-[12px] text-white placeholder:text-white/40 outline-none focus:border-[#3B82F6]"
                    />
                    <button
                      type="submit"
                      disabled={processing || !textBody.trim()}
                      className="charkle-pressable h-8 px-3 rounded-[8px] bg-[#3B82F6] hover:bg-[#2563EB] disabled:opacity-40 text-white text-[11.5px] font-medium cursor-pointer"
                    >
                      存入
                    </button>
                  </div>
                  <textarea
                    rows={2}
                    value={textBody}
                    onChange={(e) => setTextBody(e.target.value)}
                    placeholder="输入文案、设计灵感或 Markdown 片段…"
                    className="w-full p-2.5 rounded-[8px] bg-white/8 border border-white/12 text-[12px] text-white placeholder:text-white/40 outline-none focus:border-[#3B82F6] resize-none"
                  />
                </form>
              )}

              {activeTab === 'color' && (
                <form
                  onSubmit={(e) => {
                    e.preventDefault();
                    const hex = normalizeHexInput(colorHex);
                    if (!hex) {
                      pushToast({ tone: 'error', message: '请输入有效的 6 位 HEX 色值（如 #3D5A80）' });
                      return;
                    }
                    void performInputsIngest([
                      { type: 'colorSwatch', hex, title: colorTitle.trim() || `色卡 ${hex}` },
                    ]);
                    setColorTitle('');
                  }}
                  className="flex items-center gap-2"
                >
                  <input
                    type="color"
                    value={normalizeHexInput(colorHex) ?? '#3D5A80'}
                    onChange={(e) => setColorHex(e.target.value.toUpperCase())}
                    aria-label="选择颜色"
                    className="w-9 h-9 rounded-[8px] border border-white/16 bg-transparent cursor-pointer shrink-0"
                  />
                  <input
                    type="text"
                    value={colorHex}
                    onChange={(e) => setColorHex(e.target.value)}
                    placeholder="#3D5A80"
                    className="w-28 h-9 px-2.5 rounded-[8px] bg-white/8 border border-white/12 font-mono text-[12px] text-white outline-none focus:border-[#3B82F6]"
                  />
                  <input
                    type="text"
                    value={colorTitle}
                    onChange={(e) => setColorTitle(e.target.value)}
                    placeholder="色卡名称（可选）"
                    className="flex-1 h-9 px-2.5 rounded-[8px] bg-white/8 border border-white/12 text-[12px] text-white placeholder:text-white/40 outline-none focus:border-[#3B82F6]"
                  />
                  <button
                    type="submit"
                    disabled={processing}
                    className="charkle-pressable h-9 px-3.5 rounded-[8px] bg-[#3B82F6] hover:bg-[#2563EB] text-white text-[12px] font-medium cursor-pointer shrink-0"
                  >
                    保存色卡
                  </button>
                </form>
              )}

              {activeTab === 'screen' && (
                <div className="flex items-center justify-between gap-3 px-3.5 py-2.5 rounded-[12px] bg-white/[0.05] border border-white/12">
                  <div className="text-[12px] text-white/80">
                    使用浏览器原生屏幕捕获 (`getDisplayMedia`) 截取窗口或标签页高清画面并直接入库
                  </div>
                  <button
                    type="button"
                    disabled={processing}
                    onClick={() => void handleScreenCapture()}
                    className="charkle-pressable inline-flex items-center gap-1.5 h-8 px-3 rounded-[8px] bg-[#3B82F6] hover:bg-[#2563EB] text-white text-[12px] font-medium cursor-pointer shrink-0"
                  >
                    <Camera size={13} />
                    开始截屏
                  </button>
                </div>
              )}

              {/* Recent Activity Filmstrip (24 cards ranked by max(createdAt, lastOpenedAt)) */}
              {recentActivityAssets.length > 0 && (
                <div className="flex flex-col gap-1.5 pt-0.5">
                  <div className="flex items-center justify-between text-[11px] text-white/55">
                    <span>最近活动素材（可拖入情绪板或点击预览）</span>
                    <button
                      type="button"
                      onClick={() => setFullExpanded(true)}
                      className="text-white/75 hover:text-white cursor-pointer"
                    >
                      全部 ({recentActivityAssets.length})
                    </button>
                  </div>
                  <div className="flex items-center gap-2 overflow-x-auto pb-1 charkle-scroll snap-x">
                    {recentActivityAssets.slice(0, 24).map((asset: AssetRecord) => (
                      <div
                        key={asset.id}
                        role="button"
                        tabIndex={0}
                        draggable
                        onDragStart={(e) => {
                          e.dataTransfer.setData(
                            'application/x-charkle-asset-ids',
                            JSON.stringify([asset.id]),
                          );
                          e.dataTransfer.effectAllowed = 'copy';
                        }}
                        onClick={() => {
                          void markOpened(asset.id);
                          openQuickLook(asset.id);
                        }}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault();
                            void markOpened(asset.id);
                            openQuickLook(asset.id);
                          }
                        }}
                        title={asset.title}
                        className="group/thumb relative w-[92px] h-[74px] rounded-[10px] overflow-hidden bg-white/8 border border-white/10 shrink-0 snap-start cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[#5B8DEF]"
                      >
                        <img
                          src={thumbnailURL(asset.id, 'grid520', cacheBustVersion)}
                          alt={asset.title}
                          loading="lazy"
                          className="w-full h-full object-cover charkle-media-zoom"
                        />
                        <div className="absolute inset-0 bg-black/0 group-hover/thumb:bg-black/35 group-focus-visible/thumb:bg-black/35 transition-colors duration-150 flex items-end justify-between p-1.5">
                          <span className="text-[9.5px] text-white/95 truncate opacity-0 group-hover/thumb:opacity-100 group-focus-visible/thumb:opacity-100 [@media(hover:none)]:opacity-100 transition-opacity duration-150">
                            {asset.title}
                          </span>
                          <Expand
                            size={11}
                            className="text-white shrink-0 opacity-0 group-hover/thumb:opacity-100 group-focus-visible/thumb:opacity-100 [@media(hover:none)]:opacity-100 transition-opacity duration-150"
                          />
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          ) : (
            /* Expanded Full-Waterfall Dark Gallery Mode */
            <div className="p-4 flex flex-col gap-3 max-h-[64vh]">
              <div className="flex items-center justify-between gap-2">
                <div className="relative flex-1 flex items-center">
                  <Search size={13} className="absolute left-2.5 text-white/45 pointer-events-none" />
                  <input
                    type="search"
                    value={waterfallQuery}
                    onChange={(e) => setWaterfallQuery(e.target.value)}
                    placeholder="检索最近活动素材…"
                    className="w-full h-8 pl-8 pr-3 rounded-[9px] bg-white/8 border border-white/12 text-[12px] text-white placeholder:text-white/40 outline-none focus:border-[#3B82F6]"
                  />
                </div>
                <button
                  type="button"
                  onClick={() => setFullExpanded(false)}
                  className="charkle-pressable h-8 px-3 rounded-[9px] bg-white/10 hover:bg-white/16 text-[11.5px] text-white/90 cursor-pointer"
                >
                  收起
                </button>
              </div>

              <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll grid grid-cols-3 sm:grid-cols-4 gap-2 pr-0.5">
                {filteredRecentAssets.map((asset) => {
                  const primaryHex = asset.dominantColors[0]?.hex;
                  return (
                    <div
                      key={asset.id}
                      draggable
                      onDragStart={(e) => {
                        e.dataTransfer.setData(
                          'application/x-charkle-asset-ids',
                          JSON.stringify([asset.id]),
                        );
                      }}
                      onClick={() => {
                        void markOpened(asset.id);
                        openQuickLook(asset.id);
                      }}
                      className="group/wf relative aspect-[4/3] rounded-[10px] overflow-hidden bg-white/8 border border-white/10 cursor-pointer"
                    >
                      <img
                        src={thumbnailURL(asset.id, 'grid520', cacheBustVersion)}
                        alt={asset.title}
                        loading="lazy"
                        className="w-full h-full object-cover charkle-media-zoom"
                      />
                      {primaryHex && (
                        <span
                          className="absolute top-1.5 right-1.5 w-2.5 h-2.5 rounded-full"
                          style={{
                            backgroundColor: primaryHex,
                            boxShadow: isLightHex(primaryHex)
                              ? '0 0 0 1px rgba(0,0,0,0.25)'
                              : '0 0 0 1px rgba(255,255,255,0.35)',
                          }}
                        />
                      )}
                      <div className="absolute inset-x-0 bottom-0 px-2 py-1 bg-gradient-to-t from-black/75 to-transparent text-[10.5px] text-white/95 truncate">
                        {asset.title}
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          )}
        </section>
      )}
    </div>
  );
};
