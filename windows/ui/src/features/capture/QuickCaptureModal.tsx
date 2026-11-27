import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  Color16Regular,
  DocumentText16Regular,
  FolderArrowUp16Regular,
  FolderArrowUp24Regular,
  Link16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import {
  Button,
  CustomSelect,
  ModalShell,
  SegmentedControl,
  type SelectOption,
} from '../../design-system';
import { useCoordinatorStore, useLibraryStore } from '../../stores';
import { buildFolderTree, flattenFolderTree } from '../../types/domain';

type CaptureTab = 'files' | 'url' | 'text' | 'swatch';

const HEX_COLOR_RE = /^#?[0-9a-fA-F]{3}([0-9a-fA-F]{3})?$/;
const URL_IN_TEXT_RE = /(?:https?:\/\/|www\.)[^\s<>"']+/i;
const TRAILING_PUNCT_RE = /[),.;:!?\]}，。、；：！？】》」』'"“”‘’]+$/;

function extractCapturableUrl(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;
  const match = trimmed.match(URL_IN_TEXT_RE);
  if (!match) return null;
  let candidate = match[0].replace(TRAILING_PUNCT_RE, '');
  if (!/^https?:\/\//i.test(candidate)) {
    candidate = `https://${candidate}`;
  }
  try {
    const parsed = new URL(candidate);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
    if (!parsed.hostname || (!parsed.hostname.includes('.') && parsed.hostname !== 'localhost')) {
      return null;
    }
    return parsed.toString();
  } catch {
    return null;
  }
}

function normalizeHexColor(raw: string): string {
  const cleaned = raw.trim().replace(/^#/, '').replace(/[^0-9a-fA-F]/g, '').slice(0, 6);
  if (cleaned.length === 3) {
    return `#${cleaned[0]}${cleaned[0]}${cleaned[1]}${cleaned[1]}${cleaned[2]}${cleaned[2]}`.toUpperCase();
  }
  if (cleaned.length === 6) {
    return `#${cleaned}`.toUpperCase();
  }
  return '#2A60E0';
}

export const QuickCaptureModal: React.FC = () => {
  const open = useCoordinatorStore((s) => s.captureOpen);
  const setOpen = useCoordinatorStore((s) => s.setCaptureOpen);
  const destination = useCoordinatorStore((s) => s.destination);

  const folders = useLibraryStore((s) => s.folders);
  const ingestFiles = useLibraryStore((s) => s.ingestFiles);
  const ingestUrl = useLibraryStore((s) => s.ingestUrl);
  const ingestText = useLibraryStore((s) => s.ingestText);
  const ingestSwatch = useLibraryStore((s) => s.ingestSwatch);

  const urlInputRef = useRef<HTMLInputElement | null>(null);
  const textTitleInputRef = useRef<HTMLInputElement | null>(null);
  const swatchInputRef = useRef<HTMLInputElement | null>(null);

  const [tab, setTab] = useState<CaptureTab>('files');
  const [targetFolder, setTargetFolder] = useState<string>('__inbox__');
  const [url, setUrl] = useState('');
  const [urlTitle, setUrlTitle] = useState('');
  const [urlNotes, setUrlNotes] = useState('');
  const [textTitle, setTextTitle] = useState('');
  const [textBody, setTextBody] = useState('');
  const [swatchHex, setSwatchHex] = useState('#2A60E0');
  const [swatchTitle, setSwatchTitle] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);

  // Sync default destination only when modal opens so explicit '__inbox__' selection is respected
  useEffect(() => {
    if (open) {
      setTargetFolder(destination.type === 'folder' ? destination.id : '__inbox__');
      setSubmitting(false);
      setSubmitError(null);
    }
  }, [open, destination]);

  useEffect(() => {
    if (!open) return;
    setSubmitError(null);
    const raf = requestAnimationFrame(() => {
      if (tab === 'url') urlInputRef.current?.focus();
      else if (tab === 'text') textTitleInputRef.current?.focus();
      else if (tab === 'swatch') swatchInputRef.current?.focus();
    });
    return () => cancelAnimationFrame(raf);
  }, [open, tab]);

  const folderOptions = useMemo<SelectOption<string>[]>(() => {
    const flat = flattenFolderTree(buildFolderTree(folders));
    return [
      { value: '__inbox__', label: '收件箱' },
      ...flat.map((node) => ({
        value: node.folder.id,
        label: node.folder.name,
        depth: node.depth,
      })),
    ];
  }, [folders]);

  const effectiveFolderId = targetFolder === '__inbox__' ? null : targetFolder;
  const extractedUrl = useMemo(() => extractCapturableUrl(url), [url]);
  const urlHasInput = url.trim().length > 0;
  const swatchValid = HEX_COLOR_RE.test(swatchHex.trim());

  const canSubmitForm =
    tab === 'url'
      ? extractedUrl !== null
      : tab === 'text'
        ? textBody.trim().length > 0
        : tab === 'swatch'
          ? swatchValid
          : false;

  const handlePickFiles = async () => {
    setSubmitting(true);
    setSubmitError(null);
    try {
      const paths = await getTransport().pickFilesDialog();
      if (paths.length > 0) {
        await ingestFiles(paths, effectiveFolderId, destination);
        setOpen(false);
      }
    } catch (err) {
      setSubmitError(err instanceof Error && err.message ? err.message : '导入文件失败，请重试');
    } finally {
      setSubmitting(false);
    }
  };

  const handlePickPureRef = async () => {
    setSubmitting(true);
    setSubmitError(null);
    try {
      const paths = await getTransport().pickPureRefFilesDialog();
      if (paths.length > 0) {
        const results = await useLibraryStore
          .getState()
          .importPureRefScenes(paths, effectiveFolderId, true, destination);
        const totalImages = results.reduce((sum, r) => sum + r.importedAssets.length, 0);
        useCoordinatorStore.getState().pushToast({
          message: `已导入 PureRef 场景（${totalImages} 张图）并创建情绪板`,
          tone: 'success',
          durationMs: 4200,
        });
        setOpen(false);
      }
    } catch (err) {
      setSubmitError(
        err instanceof Error && err.message ? err.message : '导入 PureRef 场景失败，请重试',
      );
    } finally {
      setSubmitting(false);
    }
  };

  const submitCurrentTab = async () => {
    if (!canSubmitForm || submitting) return;
    setSubmitting(true);
    setSubmitError(null);
    try {
      if (tab === 'url' && extractedUrl) {
        await ingestUrl(
          extractedUrl,
          urlTitle.trim() || null,
          urlNotes.trim() || null,
          effectiveFolderId,
          destination,
        );
        setUrl('');
        setUrlTitle('');
        setUrlNotes('');
        setOpen(false);
      } else if (tab === 'text') {
        await ingestText(
          textTitle.trim() || '灵感笔记',
          textBody,
          null,
          effectiveFolderId,
          destination,
        );
        setTextTitle('');
        setTextBody('');
        setOpen(false);
      } else if (tab === 'swatch') {
        const normalized = normalizeHexColor(swatchHex);
        await ingestSwatch(
          normalized,
          swatchTitle.trim() || null,
          effectiveFolderId,
          destination,
        );
        setSwatchHex(normalized);
        setSwatchTitle('');
        setOpen(false);
      }
    } catch (err) {
      setSubmitError(err instanceof Error && err.message ? err.message : '保存失败，请重试');
    } finally {
      setSubmitting(false);
    }
  };

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    void submitCurrentTab();
  };

  const handleFormKeyDown = (e: React.KeyboardEvent) => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter' && canSubmitForm) {
      e.preventDefault();
      void submitCurrentTab();
    }
  };

  const previewHex = normalizeHexColor(swatchHex);

  return (
    <ModalShell
      open={open}
      onClose={() => setOpen(false)}
      title="导入素材"
      subtitle="支持本地文件、网页与仓库链接、文本笔记及色卡"
      width="md"
      footer={
        tab !== 'files' ? (
          <>
            <Button variant="standard" onClick={() => setOpen(false)}>
              取消
            </Button>
            <Button
              variant="accent"
              loading={submitting}
              disabled={!canSubmitForm}
              onClick={() => void submitCurrentTab()}
            >
              保存到素材库
            </Button>
          </>
        ) : undefined
      }
    >
      <div className="flex flex-col gap-4">
        <div className="flex items-center justify-between gap-2 flex-wrap">
          <SegmentedControl<CaptureTab>
            value={tab}
            onChange={setTab}
            options={[
              {
                value: 'files',
                label: '本地文件',
                icon: <FolderArrowUp16Regular className="w-3.5 h-3.5" />,
              },
              { value: 'url', label: '网页链接', icon: <Link16Regular className="w-3.5 h-3.5" /> },
              {
                value: 'text',
                label: '文本笔记',
                icon: <DocumentText16Regular className="w-3.5 h-3.5" />,
              },
              { value: 'swatch', label: '色卡', icon: <Color16Regular className="w-3.5 h-3.5" /> },
            ]}
          />

          <CustomSelect<string>
            value={targetFolder}
            options={folderOptions}
            onChange={setTargetFolder}
            ariaLabel="保存目标位置"
            size="xs"
            className="max-w-[180px]"
          />
        </div>

        {tab === 'files' && (
          <div className="py-8 px-6 rounded-[var(--win-radius-card)] border border-dashed border-[var(--border-strong)] bg-[var(--bg-gallery)] flex flex-col items-center justify-center gap-3 text-center">
            <FolderArrowUp24Regular className="w-7 h-7 text-[var(--accent)]" />
            <div className="text-[13.5px] font-medium text-[var(--text-primary)]">
              选择图片、视频、音频、PDF、文档、3D 模型或 PureRef (.pur) 场景
            </div>
            <p className="text-[12px] text-[var(--text-secondary)]">
              也可直接将文件或 .pur 场景拖入画廊，或按 Ctrl+V 粘贴剪贴板图片与链接。
            </p>
            <div className="flex items-center gap-2 flex-wrap justify-center">
              <Button variant="accent" loading={submitting} onClick={() => void handlePickFiles()}>
                选择文件…
              </Button>
              <Button
                variant="standard"
                loading={submitting}
                data-testid="capture-import-pureref"
                onClick={() => void handlePickPureRef()}
              >
                导入 PureRef (.pur)…
              </Button>
            </div>
          </div>
        )}

        {tab === 'url' && (
          <form onSubmit={handleSubmit} onKeyDown={handleFormKeyDown} className="flex flex-col gap-3">
            <button type="submit" className="hidden" aria-hidden="true" />
            <div className="flex flex-col gap-1">
              <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                链接地址（支持任意网页、YouTube / B 站视频、小红书、推文及 GitHub 仓库）
              </label>
              <input
                ref={urlInputRef}
                type="text"
                inputMode="url"
                autoFocus
                value={url}
                onChange={(e) => {
                  setUrl(e.target.value);
                  setSubmitError(null);
                }}
                placeholder="https://... 或直接粘贴 YouTube / B 站 / 小红书 / 推文 / 网页链接"
                className="win-input-elevation h-9 px-3 rounded-[var(--win-radius-control)] text-[13px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
              />
              {urlHasInput && extractedUrl && extractedUrl !== url.trim() && (
                <p className="text-[11px] text-[var(--accent)] truncate">
                  已识别链接：{extractedUrl}
                </p>
              )}
              {urlHasInput && !extractedUrl && (
                <p className="text-[11px] text-[var(--danger)]">
                  请输入有效的 http:// 或 https:// 链接
                </p>
              )}
            </div>
            <div className="flex flex-col gap-1">
              <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                标题（可选，留空自动抓取）
              </label>
              <input
                type="text"
                value={urlTitle}
                onChange={(e) => setUrlTitle(e.target.value)}
                placeholder="自定义标题…"
                className="win-input-elevation h-9 px-3 rounded-[var(--win-radius-control)] text-[13px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
              />
            </div>
            <div className="flex flex-col gap-1">
              <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                备注（可选）
              </label>
              <textarea
                rows={3}
                value={urlNotes}
                onChange={(e) => setUrlNotes(e.target.value)}
                placeholder="记录参考说明…"
                className="win-input-elevation p-2.5 rounded-[var(--win-radius-control)] text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none resize-none"
              />
            </div>
          </form>
        )}

        {tab === 'text' && (
          <form onSubmit={handleSubmit} onKeyDown={handleFormKeyDown} className="flex flex-col gap-3">
            <button type="submit" className="hidden" aria-hidden="true" />
            <div className="flex flex-col gap-1">
              <label className="text-[12px] font-medium text-[var(--text-secondary)]">标题</label>
              <input
                ref={textTitleInputRef}
                type="text"
                autoFocus
                value={textTitle}
                onChange={(e) => setTextTitle(e.target.value)}
                placeholder="例如：排版原则笔记…"
                className="win-input-elevation h-9 px-3 rounded-[var(--win-radius-control)] text-[13px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
              />
            </div>
            <div className="flex flex-col gap-1">
              <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                Markdown / 正文
              </label>
              <textarea
                rows={6}
                required
                value={textBody}
                onChange={(e) => {
                  setTextBody(e.target.value);
                  setSubmitError(null);
                }}
                placeholder="支持 Markdown 标题、列表与代码块…"
                className="win-input-elevation p-2.5 rounded-[var(--win-radius-control)] text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none charkle-mono"
              />
            </div>
          </form>
        )}

        {tab === 'swatch' && (
          <form onSubmit={handleSubmit} onKeyDown={handleFormKeyDown} className="flex flex-col gap-3">
            <button type="submit" className="hidden" aria-hidden="true" />
            <div className="flex items-center gap-3">
              <input
                type="color"
                value={previewHex}
                onChange={(e) => {
                  setSwatchHex(e.target.value.toUpperCase());
                  setSubmitError(null);
                }}
                aria-label="选择颜色"
                className="h-12 w-16 rounded-[var(--win-radius-control)] border border-[var(--win-stroke-control)] cursor-pointer bg-transparent"
              />
              <div className="flex-1 flex flex-col gap-1">
                <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                  色值（HEX）
                </label>
                <input
                  ref={swatchInputRef}
                  type="text"
                  value={swatchHex}
                  onChange={(e) => {
                    setSwatchHex(e.target.value.toUpperCase());
                    setSubmitError(null);
                  }}
                  onBlur={() => {
                    if (HEX_COLOR_RE.test(swatchHex.trim())) {
                      setSwatchHex(normalizeHexColor(swatchHex));
                    }
                  }}
                  placeholder="#2A60E0"
                  className="win-input-elevation h-9 px-3 rounded-[var(--win-radius-control)] text-[13px] charkle-mono text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
                />
              </div>
            </div>
            {swatchHex.trim().length > 0 && !swatchValid && (
              <p className="text-[11px] text-[var(--danger)]">
                请输入 3 位或 6 位有效 HEX 色值（例如 #2A60E0）
              </p>
            )}
            <div className="flex flex-col gap-1">
              <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                色卡名称（可选）
              </label>
              <input
                type="text"
                value={swatchTitle}
                onChange={(e) => setSwatchTitle(e.target.value)}
                placeholder="例如：暖石膏、深海蓝…"
                className="win-input-elevation h-9 px-3 rounded-[var(--win-radius-control)] text-[13px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
              />
            </div>
          </form>
        )}

        {submitError && (
          <div
            role="alert"
            className="px-3 py-2 rounded-[var(--win-radius-control)] bg-[var(--danger)]/10 border border-[var(--danger)]/25 text-[12px] text-[var(--danger)]"
          >
            {submitError}
          </div>
        )}
      </div>
    </ModalShell>
  );
};
