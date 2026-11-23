import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  Camera,
  FileText,
  Folder,
  Inbox,
  LayoutGrid,
  Link2,
  Palette,
  Pipette,
  Puzzle,
  Trash2,
  Upload,
} from 'lucide-react';
import { labFromHex, parseHex } from '@charkle/shared';
import type { CaptureInput } from '@charkle/shared';
import { Button, formatBytes, ModalShell } from '../../design-system';
import type { CaptureTarget, QuickCaptureTab } from '../../stores/coordinatorStore';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import {
  captureScreenFrame,
  detectURLFromText,
  normalizeHexInput,
} from './captureUtils';

interface EyeDropperResult {
  sRGBHex: string;
}

interface EyeDropperConstructor {
  new (): { open: () => Promise<EyeDropperResult> };
}

function getEyeDropperAPI(): EyeDropperConstructor | null {
  if (typeof window === 'undefined') return null;
  const w = window as unknown as { EyeDropper?: EyeDropperConstructor };
  return typeof w.EyeDropper === 'function' ? w.EyeDropper : null;
}

const TABS: ReadonlyArray<{
  id: QuickCaptureTab;
  label: string;
  icon: React.FC<{ size?: number; className?: string }>;
}> = [
  { id: 'upload', label: '文件上传', icon: Upload },
  { id: 'url', label: '网页与社媒链接', icon: Link2 },
  { id: 'note', label: '文字灵感', icon: FileText },
  { id: 'color', label: '色卡取色', icon: Palette },
  { id: 'screen', label: '屏幕截屏', icon: Camera },
];

export const QuickCaptureModal: React.FC = () => {
  const open = useCoordinatorStore((s) => s.showQuickCapture);
  const prefill = useCoordinatorStore((s) => s.quickCapturePrefill);
  const closeQuickCapture = useCoordinatorStore((s) => s.closeQuickCapture);
  const captureTarget = useCoordinatorStore((s) => s.captureTarget);
  const setCaptureTarget = useCoordinatorStore((s) => s.setCaptureTarget);
  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
  const openSettings = useCoordinatorStore((s) => s.openSettings);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const folders = useLibraryStore((s) => s.folders);
  const uploadFiles = useLibraryStore((s) => s.uploadFiles);
  const ingestInputs = useLibraryStore((s) => s.ingestInputs);

  const boards = useMoodboardStore((s) => s.boards);

  const [tab, setTab] = useState<QuickCaptureTab>('upload');
  const [submitting, setSubmitting] = useState(false);

  // Tab 1: Upload
  const [queuedFiles, setQueuedFiles] = useState<File[]>([]);
  const [fileDragOver, setFileDragOver] = useState(false);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  // Tab 2: URL
  const [urlValue, setUrlValue] = useState('');
  const [urlTitle, setUrlTitle] = useState('');
  const [urlNotes, setUrlNotes] = useState('');

  // Tab 3: Note
  const [noteTitle, setNoteTitle] = useState('');
  const [noteText, setNoteText] = useState('');

  // Tab 4: Color Swatch
  const [hexInput, setHexInput] = useState('#2A60E0');
  const [colorTitle, setColorTitle] = useState('');
  const [pickingEyeDropper, setPickingEyeDropper] = useState(false);

  // Tab 5: Screen Capture
  const [capturingScreen, setCapturingScreen] = useState(false);
  const [capturedScreenInput, setCapturedScreenInput] = useState<
    Extract<CaptureInput, { type: 'imageData' }> | null
  >(null);

  const activeBoard = useMemo(
    () => boards.find((b) => b.id === activeBoardID) ?? boards[0] ?? null,
    [boards, activeBoardID],
  );

  // Sync prefill state whenever modal opens
  useEffect(() => {
    if (!open) return;
    setSubmitting(false);
    setQueuedFiles([]);
    setCapturedScreenInput(null);

    if (prefill) {
      setTab(
        prefill.tab ??
          (prefill.url ? 'url' : prefill.hex ? 'color' : prefill.text ? 'note' : 'upload'),
      );
      setUrlValue(prefill.url ?? '');
      setUrlTitle(prefill.title ?? '');
      setUrlNotes(prefill.url ? prefill.text ?? '' : '');
      setNoteTitle(prefill.url ? '' : prefill.title ?? '');
      setNoteText(prefill.url ? '' : prefill.text ?? '');
      if (prefill.hex) {
        const normalized = normalizeHexInput(prefill.hex);
        if (normalized) setHexInput(normalized);
      }
      setColorTitle('');
    } else {
      setUrlValue('');
      setUrlTitle('');
      setUrlNotes('');
      setNoteTitle('');
      setNoteText('');
      setColorTitle('');
    }
  }, [open, prefill]);

  const resolvedOpts = useMemo(() => {
    if (captureTarget.type === 'folder') {
      const exists = folders.find((f) => f.id === captureTarget.folderID);
      if (exists) {
        return {
          targetFolderID: exists.id,
          targetBoardID: null,
          label: `文件夹「${exists.name}」`,
        };
      }
    }
    if (captureTarget.type === 'activeMoodboard' && activeBoard) {
      return {
        targetFolderID: null,
        targetBoardID: activeBoard.id,
        label: `情绪板「${activeBoard.title}」`,
      };
    }
    return { targetFolderID: null, targetBoardID: null, label: '收件箱' };
  }, [captureTarget, folders, activeBoard]);

  const detectedURL = useMemo(() => detectURLFromText(urlValue), [urlValue]);
  const validHex = useMemo(() => normalizeHexInput(hexInput) ?? '#2A60E0', [hexInput]);
  const swatchRGB = useMemo(() => parseHex(validHex), [validHex]);
  const swatchLab = useMemo(() => labFromHex(validHex), [validHex]);
  const hasEyeDropper = Boolean(getEyeDropperAPI());

  const handleSelectTargetType = (type: CaptureTarget['type']) => {
    if (type === 'inbox') {
      setCaptureTarget({ type: 'inbox' });
    } else if (type === 'folder') {
      const firstID =
        captureTarget.type === 'folder' ? captureTarget.folderID : folders[0]?.id;
      if (firstID) {
        setCaptureTarget({ type: 'folder', folderID: firstID });
      } else {
        pushToast({ tone: 'info', message: '请先在左侧边栏创建一个文件夹' });
      }
    } else if (type === 'activeMoodboard') {
      if (activeBoard) {
        setCaptureTarget({ type: 'activeMoodboard' });
      } else {
        pushToast({ tone: 'info', message: '暂无情绪板，请先新建或生成情绪板' });
      }
    }
  };

  const handleSubmitUpload = async () => {
    if (queuedFiles.length === 0) return;
    setSubmitting(true);
    try {
      const created = await uploadFiles(queuedFiles, {
        targetFolderID: resolvedOpts.targetFolderID,
        targetBoardID: resolvedOpts.targetBoardID,
      });
      pushToast({
        tone: 'success',
        message: `已上传 ${created.length} 项素材至${resolvedOpts.label}`,
      });
      closeQuickCapture();
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '上传文件失败',
      });
    } finally {
      setSubmitting(false);
    }
  };

  const handleSubmitURL = async () => {
    const trimmed = urlValue.trim();
    const detected = detectURLFromText(trimmed);
    if (!detected) {
      pushToast({ tone: 'error', message: '请输入有效的 http:// 或 https:// 链接' });
      return;
    }
    setSubmitting(true);
    try {
      const inputs: CaptureInput[] = [
        {
          type: 'webURL',
          url: detected.url,
          title: urlTitle.trim() || undefined,
        },
      ];
      if (urlNotes.trim()) {
        inputs.push({
          type: 'textSnippet',
          title: urlTitle.trim() ? `${urlTitle.trim()} · 摘录` : '网页摘录',
          text: `${urlNotes.trim()}\n\n来源：${detected.url}`,
        });
      }
      const created = await ingestInputs(inputs, {
        targetFolderID: resolvedOpts.targetFolderID,
        targetBoardID: resolvedOpts.targetBoardID,
      });
      pushToast({
        tone: 'success',
        message: `已收藏${detected.badge}（${created.length} 项）至${resolvedOpts.label}`,
      });
      closeQuickCapture();
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '收藏链接失败',
      });
    } finally {
      setSubmitting(false);
    }
  };

  const handleSubmitNote = async () => {
    const text = noteText.trim();
    if (!text) return;
    const fallbackTitle = text.split(/\r?\n/)[0]?.trim().slice(0, 48) || '灵感笔记';
    setSubmitting(true);
    try {
      await ingestInputs(
        [
          {
            type: 'textSnippet',
            title: noteTitle.trim() || fallbackTitle,
            text,
          },
        ],
        {
          targetFolderID: resolvedOpts.targetFolderID,
          targetBoardID: resolvedOpts.targetBoardID,
        },
      );
      pushToast({
        tone: 'success',
        message: `已保存文字灵感至${resolvedOpts.label}`,
      });
      closeQuickCapture();
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存文字灵感失败',
      });
    } finally {
      setSubmitting(false);
    }
  };

  const handlePickEyeDropper = async () => {
    const EyeDropperAPI = getEyeDropperAPI();
    if (!EyeDropperAPI) return;
    setPickingEyeDropper(true);
    try {
      const dropper = new EyeDropperAPI();
      const result = await dropper.open();
      const normalized = normalizeHexInput(result.sRGBHex);
      if (normalized) {
        setHexInput(normalized);
      }
    } catch {
      // User cancelled EyeDropper
    } finally {
      setPickingEyeDropper(false);
    }
  };

  const handleSubmitColor = async () => {
    const hex = normalizeHexInput(hexInput);
    if (!hex) {
      pushToast({ tone: 'error', message: '请输入有效的 6 位 HEX 色值，例如 #2A60E0' });
      return;
    }
    setSubmitting(true);
    try {
      await ingestInputs(
        [
          {
            type: 'colorSwatch',
            hex,
            title: colorTitle.trim() || `色卡 ${hex}`,
          },
        ],
        {
          targetFolderID: resolvedOpts.targetFolderID,
          targetBoardID: resolvedOpts.targetBoardID,
        },
      );
      pushToast({
        tone: 'success',
        message: `已采集色卡 ${hex} 至${resolvedOpts.label}`,
      });
      closeQuickCapture();
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存色卡失败',
      });
    } finally {
      setSubmitting(false);
    }
  };

  const handleStartScreenCapture = async () => {
    setCapturingScreen(true);
    try {
      const frame = await captureScreenFrame();
      if (frame.type === 'imageData') {
        setCapturedScreenInput(frame);
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : '屏幕截屏已取消或失败';
      if (!message.includes('Permission denied') && !message.includes('NotAllowedError')) {
        pushToast({ tone: 'error', message });
      }
    } finally {
      setCapturingScreen(false);
    }
  };

  const handleSaveScreenCapture = async () => {
    if (!capturedScreenInput) return;
    setSubmitting(true);
    try {
      await ingestInputs([capturedScreenInput], {
        targetFolderID: resolvedOpts.targetFolderID,
        targetBoardID: resolvedOpts.targetBoardID,
      });
      pushToast({
        tone: 'success',
        message: `已保存屏幕截图至${resolvedOpts.label}`,
      });
      closeQuickCapture();
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存截图失败',
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={closeQuickCapture}
      title="快速采集"
      width="lg"
      noPadding
      className="max-w-[660px]"
    >
      <div className="flex flex-col">
      {/* 5 Capture Mode Tabs */}
      <div className="px-5 pt-3 pb-2 shrink-0">
        <div
          role="tablist"
          aria-label="采集方式"
          className="grid grid-cols-5 gap-1 p-1 rounded-[var(--radius-settings-outer)] bg-[var(--bg-subtle)]/85 border border-[var(--border-hairline)]"
        >
          {TABS.map((item) => {
            const Icon = item.icon;
            const active = tab === item.id;
            return (
              <button
                key={item.id}
                type="button"
                role="tab"
                aria-selected={active}
                onClick={() => setTab(item.id)}
                className={[
                  'charkle-pressable h-8 px-2 rounded-[var(--radius-settings-inner)] text-[12px] font-medium inline-flex items-center justify-center gap-1.5 cursor-pointer truncate',
                  active
                    ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-xs'
                    : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                ].join(' ')}
              >
                <Icon size={13.5} className={active ? 'text-[var(--accent)] shrink-0' : 'shrink-0'} />
                <span className="truncate">{item.label}</span>
              </button>
            );
          })}
        </div>
      </div>

      {/* Target Destination Selector */}
      <div className="px-5 py-2 flex flex-wrap items-center gap-2 border-b border-[var(--border-hairline)] shrink-0">
        <span className="text-[11.5px] font-medium text-[var(--text-tertiary)] shrink-0">
          采集目标
        </span>
        <div className="flex flex-wrap items-center gap-1.5 flex-1 min-w-0">
          <button
            type="button"
            onClick={() => handleSelectTargetType('inbox')}
            className={[
              'charkle-pressable h-7 px-2.5 rounded-[var(--radius-chip)] text-[12px] inline-flex items-center gap-1.5 border cursor-pointer',
              captureTarget.type === 'inbox'
                ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)] font-medium'
                : 'bg-[var(--bg-subtle)]/70 border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
            ].join(' ')}
          >
            <Inbox size={12.5} />
            收件箱
          </button>

          <button
            type="button"
            onClick={() => handleSelectTargetType('folder')}
            className={[
              'charkle-pressable h-7 px-2.5 rounded-[var(--radius-chip)] text-[12px] inline-flex items-center gap-1.5 border cursor-pointer',
              captureTarget.type === 'folder'
                ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)] font-medium'
                : 'bg-[var(--bg-subtle)]/70 border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
            ].join(' ')}
          >
            <Folder size={12.5} />
            指定文件夹
          </button>

          {captureTarget.type === 'folder' && folders.length > 0 && (
            <select
              aria-label="选择目标文件夹"
              value={captureTarget.folderID}
              onChange={(e) => setCaptureTarget({ type: 'folder', folderID: e.target.value })}
              className="h-7 px-2 text-[12px] rounded-[var(--radius-chip)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)] max-w-[160px]"
            >
              {folders.map((folder) => (
                <option key={folder.id} value={folder.id}>
                  {folder.name}
                </option>
              ))}
            </select>
          )}

          <button
            type="button"
            disabled={!activeBoard}
            onClick={() => handleSelectTargetType('activeMoodboard')}
            className={[
              'charkle-pressable h-7 px-2.5 rounded-[var(--radius-chip)] text-[12px] inline-flex items-center gap-1.5 border cursor-pointer disabled:opacity-45',
              captureTarget.type === 'activeMoodboard'
                ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)] font-medium'
                : 'bg-[var(--bg-subtle)]/70 border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
            ].join(' ')}
          >
            <LayoutGrid size={12.5} />
            <span className="truncate max-w-[140px]">
              {activeBoard ? `情绪板 · ${activeBoard.title}` : '当前活跃情绪板'}
            </span>
          </button>
        </div>
      </div>

      {/* Tab Panel Body */}
      <div className="p-5 overflow-y-auto charkle-scroll flex-1 min-h-0">
        {tab === 'upload' && (
          <div className="flex flex-col gap-3.5">
            <input
              ref={fileInputRef}
              type="file"
              multiple
              className="hidden"
              onChange={(e) => {
                const picked = Array.from(e.target.files ?? []);
                if (picked.length > 0) {
                  setQueuedFiles((prev) => [...prev, ...picked]);
                }
                e.target.value = '';
              }}
            />

            <div
              onDragOver={(e) => {
                e.preventDefault();
                setFileDragOver(true);
              }}
              onDragLeave={() => setFileDragOver(false)}
              onDrop={(e) => {
                e.preventDefault();
                setFileDragOver(false);
                const dropped = Array.from(e.dataTransfer.files ?? []);
                if (dropped.length > 0) {
                  setQueuedFiles((prev) => [...prev, ...dropped]);
                }
              }}
              onClick={() => fileInputRef.current?.click()}
              className={[
                'rounded-[var(--radius-settings-outer)] border-2 border-dashed p-7 text-center cursor-pointer flex flex-col items-center gap-2',
                'transition-[background-color,border-color] duration-[var(--duration-press)] ease-[var(--ease-out)]',
                fileDragOver
                  ? 'border-[var(--accent)] bg-[var(--accent-soft)]'
                  : 'border-[var(--border-strong)] bg-[var(--bg-gallery)]/70 hover:border-[var(--accent)]/65',
              ].join(' ')}
            >
              <div className="h-10 w-10 rounded-[var(--radius-settings-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] flex items-center justify-center text-[var(--text-secondary)]">
                <Upload size={18} />
              </div>
              <div className="text-[13.5px] font-medium text-[var(--text-primary)]">
                拖入文件，或点击选择本地文件
              </div>
              <div className="text-[12px] text-[var(--text-tertiary)]">
                支持图片、视频、音频、文档与 3D 文件
              </div>
            </div>

            {queuedFiles.length > 0 && (
              <div className="flex flex-col gap-1.5 max-h-[180px] overflow-y-auto charkle-scroll">
                {queuedFiles.map((file, idx) => (
                  <div
                    key={`${file.name}-${file.size}-${idx}`}
                    className="flex items-center justify-between gap-2 px-3 py-2 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] text-[12.5px]"
                  >
                    <span className="truncate text-[var(--text-primary)] font-medium">
                      {file.name}
                    </span>
                    <div className="flex items-center gap-2 shrink-0">
                      <span className="text-[11px] font-mono text-[var(--text-tertiary)]">
                        {formatBytes(file.size)}
                      </span>
                      <button
                        type="button"
                        aria-label={`移除 ${file.name}`}
                        onClick={() =>
                          setQueuedFiles((prev) => prev.filter((_, i) => i !== idx))
                        }
                        className="text-[var(--text-tertiary)] hover:text-[var(--danger)] cursor-pointer"
                      >
                        <Trash2 size={13} />
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            )}

            <div className="flex justify-end gap-2 pt-1">
              <Button variant="ghost" size="sm" onClick={closeQuickCapture}>
                取消
              </Button>
              <Button
                variant="primary"
                size="sm"
                loading={submitting}
                disabled={queuedFiles.length === 0}
                onClick={() => void handleSubmitUpload()}
              >
                <Upload size={13.5} />
                导入 {queuedFiles.length > 0 ? `${queuedFiles.length} 个文件` : '素材'}
              </Button>
            </div>
          </div>
        )}

        {tab === 'url' && (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void handleSubmitURL();
            }}
            className="flex flex-col gap-3.5"
          >
            <div className="flex flex-col gap-1.5">
              <div className="flex items-center justify-between">
                <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                  网页 / X / Threads / Bluesky / GitHub 链接
                </label>
                {detectedURL && (
                  <span className="px-2 py-0.5 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11px] font-medium">
                    已识别：{detectedURL.badge}
                  </span>
                )}
              </div>
              <input
                type="url"
                autoFocus
                required
                value={urlValue}
                onChange={(e) => setUrlValue(e.target.value)}
                placeholder="https://x.com/... 或 https://github.com/owner/repo"
                className="h-9.5 px-3 text-[13px] rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)] focus:ring-2 focus:ring-[var(--accent-ring)]"
              />
            </div>

            <div className="flex flex-col gap-1.5">
              <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                标题（可选，留空自动抓取网页标题）
              </label>
              <input
                type="text"
                value={urlTitle}
                onChange={(e) => setUrlTitle(e.target.value)}
                placeholder="自定义标题…"
                className="h-9 px-3 text-[13px] rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)]"
              />
            </div>

            {urlNotes && (
              <div className="flex flex-col gap-1.5">
                <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                  顺带保存网页选中文本摘录（可选）
                </label>
                <textarea
                  rows={3}
                  value={urlNotes}
                  onChange={(e) => setUrlNotes(e.target.value)}
                  className="p-2.5 text-[12.5px] leading-relaxed rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)] resize-y"
                />
              </div>
            )}

            <div className="flex justify-end gap-2 pt-1">
              <Button variant="ghost" size="sm" onClick={closeQuickCapture}>
                取消
              </Button>
              <Button
                type="submit"
                variant="primary"
                size="sm"
                loading={submitting}
                disabled={!detectedURL}
              >
                <Link2 size={13.5} />
                收藏链接
              </Button>
            </div>
          </form>
        )}

        {tab === 'note' && (
          <div className="flex flex-col gap-3">
            <input
              type="text"
              value={noteTitle}
              onChange={(e) => setNoteTitle(e.target.value)}
              placeholder="标题（可选，留空取首行）"
              className="h-9 px-3 text-[13px] rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)]"
            />
            <textarea
              autoFocus
              rows={6}
              value={noteText}
              onChange={(e) => setNoteText(e.target.value)}
              onKeyDown={(e) => {
                if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && noteText.trim()) {
                  e.preventDefault();
                  void handleSubmitNote();
                }
              }}
              placeholder="输入文案片段、提示词、设计灵感或 Markdown 笔记…（⌘Enter 快速保存）"
              className="p-3 text-[13px] leading-relaxed rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)] resize-y"
            />
            <div className="flex justify-end gap-2">
              <Button variant="ghost" size="sm" onClick={closeQuickCapture}>
                取消
              </Button>
              <Button
                variant="primary"
                size="sm"
                loading={submitting}
                disabled={!noteText.trim()}
                onClick={() => void handleSubmitNote()}
              >
                <FileText size={13.5} />
                保存文字灵感
              </Button>
            </div>
          </div>
        )}

        {tab === 'color' && (
          <div className="flex flex-col gap-4">
            <div className="flex items-stretch gap-4">
              <div
                className="w-36 h-32 rounded-[var(--radius-settings-outer)] border border-[var(--border-hairline)] shrink-0 shadow-xs flex items-end p-2.5"
                style={{ backgroundColor: validHex }}
              >
                <span className="px-2 py-0.5 rounded-[6px] bg-black/45 backdrop-blur-xs text-white text-[11.5px] font-mono">
                  {validHex}
                </span>
              </div>

              <div className="flex-1 min-w-0 flex flex-col gap-2.5">
                <div className="flex items-center gap-2">
                  <input
                    type="color"
                    aria-label="选择颜色"
                    value={validHex}
                    onChange={(e) => setHexInput(e.target.value.toUpperCase())}
                    className="h-9 w-11 p-0.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] cursor-pointer shrink-0"
                  />
                  <input
                    type="text"
                    value={hexInput}
                    onChange={(e) => setHexInput(e.target.value)}
                    placeholder="#2A60E0"
                    className="flex-1 min-w-0 h-9 px-3 font-mono text-[13px] rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
                  />
                  <Button
                    variant="secondary"
                    size="sm"
                    disabled={!hasEyeDropper}
                    loading={pickingEyeDropper}
                    title={
                      hasEyeDropper
                        ? '使用屏幕吸管取色'
                        : '当前浏览器不支持屏幕吸管（建议使用 Chrome / Edge）'
                    }
                    onClick={() => void handlePickEyeDropper()}
                  >
                    <Pipette size={13.5} />
                    屏幕吸管
                  </Button>
                </div>

                <input
                  type="text"
                  value={colorTitle}
                  onChange={(e) => setColorTitle(e.target.value)}
                  placeholder="色卡名称（可选，如：青瓷釉色）"
                  className="h-9 px-3 text-[13px] rounded-[var(--radius-settings-inner)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)]"
                />

                <div className="text-[11.5px] font-mono text-[var(--text-tertiary)] flex flex-wrap gap-x-3 gap-y-0.5">
                  <span>
                    RGB{' '}
                    {swatchRGB
                      ? `${Math.round(swatchRGB.r * 255)}, ${Math.round(swatchRGB.g * 255)}, ${Math.round(swatchRGB.b * 255)}`
                      : '—'}
                  </span>
                  <span>
                    Lab L{swatchLab.l.toFixed(0)} a{swatchLab.a.toFixed(0)} b
                    {swatchLab.b.toFixed(0)}
                  </span>
                </div>
              </div>
            </div>

            <div className="flex justify-end gap-2">
              <Button variant="ghost" size="sm" onClick={closeQuickCapture}>
                取消
              </Button>
              <Button
                variant="primary"
                size="sm"
                loading={submitting}
                disabled={!normalizeHexInput(hexInput)}
                onClick={() => void handleSubmitColor()}
              >
                <Palette size={13.5} />
                采集色卡
              </Button>
            </div>
          </div>
        )}

        {tab === 'screen' && (
          <div className="flex flex-col gap-3.5">
            {capturedScreenInput ? (
              <div className="flex flex-col gap-3">
                <div className="rounded-[var(--radius-settings-outer)] overflow-hidden border border-[var(--border-hairline)] bg-[var(--bg-gallery)] max-h-[260px] flex items-center justify-center p-2">
                  <img
                    src={`data:image/png;base64,${capturedScreenInput.base64Data}`}
                    alt="屏幕截屏预览"
                    className="max-h-[240px] max-w-full object-contain rounded-[var(--radius-settings-inner)]"
                  />
                </div>
                <div className="flex items-center justify-between gap-2">
                  <span className="text-[12px] font-mono text-[var(--text-tertiary)] truncate">
                    {capturedScreenInput.suggestedName}
                  </span>
                  <div className="flex items-center gap-2 shrink-0">
                    <Button
                      variant="secondary"
                      size="sm"
                      loading={capturingScreen}
                      onClick={() => void handleStartScreenCapture()}
                    >
                      重新截屏
                    </Button>
                    <Button
                      variant="primary"
                      size="sm"
                      loading={submitting}
                      onClick={() => void handleSaveScreenCapture()}
                    >
                      保存至{resolvedOpts.label}
                    </Button>
                  </div>
                </div>
              </div>
            ) : (
              <div className="rounded-[var(--radius-settings-outer)] border border-[var(--border-hairline)] bg-[var(--bg-gallery)]/75 p-7 flex flex-col items-center text-center gap-3">
                <div className="h-11 w-11 rounded-[var(--radius-settings-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] flex items-center justify-center text-[var(--text-secondary)]">
                  <Camera size={20} />
                </div>
                <div className="flex flex-col gap-1 max-w-[360px]">
                  <div className="text-[13.5px] font-medium text-[var(--text-primary)]">
                    截取窗口、标签页或屏幕画面
                  </div>
                </div>
                <Button
                  variant="primary"
                  size="sm"
                  loading={capturingScreen}
                  onClick={() => void handleStartScreenCapture()}
                >
                  <Camera size={14} />
                  开始屏幕截屏
                </Button>
              </div>
            )}
          </div>
        )}
      </div>

      {/* Footer: Browser Clipper Extension Link */}
      <div className="px-5 py-3 border-t border-[var(--border-hairline)] bg-[var(--bg-gallery)]/60 flex items-center justify-between gap-2 text-[12px] shrink-0">
        <button
          type="button"
          onClick={() => {
            closeQuickCapture();
            openSettings('extensions');
          }}
          className="inline-flex items-center gap-1.5 font-medium text-[var(--text-secondary)] hover:text-[var(--accent)] cursor-pointer"
        >
          <Puzzle size={14} className="text-[var(--accent)] shrink-0" />
          安装浏览器采集扩展
        </button>
        <span className="text-[11px] font-mono text-[var(--text-tertiary)] shrink-0">
          ⇧⌘N
        </span>
      </div>
      </div>
    </ModalShell>
  );
};
