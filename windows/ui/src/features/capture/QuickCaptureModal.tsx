import React, { useMemo, useState } from 'react';
import { FileText, FolderUp, Link2, Palette } from 'lucide-react';
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

export const QuickCaptureModal: React.FC = () => {
  const open = useCoordinatorStore((s) => s.captureOpen);
  const setOpen = useCoordinatorStore((s) => s.setCaptureOpen);
  const destination = useCoordinatorStore((s) => s.destination);

  const folders = useLibraryStore((s) => s.folders);
  const ingestFiles = useLibraryStore((s) => s.ingestFiles);
  const ingestUrl = useLibraryStore((s) => s.ingestUrl);
  const ingestText = useLibraryStore((s) => s.ingestText);
  const ingestSwatch = useLibraryStore((s) => s.ingestSwatch);

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

  const folderOptions = useMemo<SelectOption<string>[]>(() => {
    const flat = flattenFolderTree(buildFolderTree(folders));
    return [
      { value: '__inbox__', label: '收件箱（稍后整理）' },
      ...flat.map((node) => ({
        value: node.folder.id,
        label: node.folder.name,
        depth: node.depth,
      })),
    ];
  }, [folders]);

  const effectiveFolderId =
    targetFolder === '__inbox__'
      ? destination.type === 'folder'
        ? destination.id
        : null
      : targetFolder;

  const handlePickFiles = async () => {
    setSubmitting(true);
    try {
      const paths = await getTransport().pickFilesDialog();
      if (paths.length > 0) {
        await ingestFiles(paths, effectiveFolderId, destination);
        setOpen(false);
      }
    } finally {
      setSubmitting(false);
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSubmitting(true);
    try {
      if (tab === 'url') {
        if (!url.trim()) return;
        await ingestUrl(
          url.trim(),
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
        if (!textBody.trim()) return;
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
        await ingestSwatch(
          swatchHex,
          swatchTitle.trim() || null,
          effectiveFolderId,
          destination,
        );
        setSwatchTitle('');
        setOpen(false);
      }
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={() => setOpen(false)}
      title="导入与采集素材"
      subtitle="支持本地多媒体、网页与仓库链接、Markdown 笔记及灵感色卡"
      width="md"
      footer={
        tab !== 'files' ? (
          <>
            <Button variant="secondary" onClick={() => setOpen(false)}>
              取消
            </Button>
            <Button variant="primary" loading={submitting} onClick={handleSubmit}>
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
              { value: 'files', label: '本地文件', icon: <FolderUp size={13} /> },
              { value: 'url', label: '网页链接', icon: <Link2 size={13} /> },
              { value: 'text', label: '文本笔记', icon: <FileText size={13} /> },
              { value: 'swatch', label: '灵感色卡', icon: <Palette size={13} /> },
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
          <div className="py-8 px-6 rounded-[var(--radius-settings-outer)] border border-dashed border-[var(--border-strong)] bg-[var(--bg-gallery)] flex flex-col items-center justify-center gap-3 text-center">
            <FolderUp size={28} className="text-[var(--accent)]" />
            <div className="text-[13.5px] font-medium text-[var(--text-primary)]">
              选择本地图片、视频、音频、PDF、Markdown 或 3D 模型
            </div>
            <p className="text-[12px] text-[var(--text-secondary)]">
              也可以直接将文件拖入画廊窗口，或使用 Ctrl+V 粘贴剪贴板图片与链接。
            </p>
            <Button variant="primary" loading={submitting} onClick={() => void handlePickFiles()}>
              打开系统文件选择器
            </Button>
          </div>
        )}

        {tab === 'url' && (
          <form onSubmit={handleSubmit} className="flex flex-col gap-3">
            <div className="flex flex-col gap-1">
              <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                链接地址（自动识别 GitHub 仓库与社交动态）
              </label>
              <input
                type="url"
                required
                autoFocus
                value={url}
                onChange={(e) => setUrl(e.target.value)}
                placeholder="https://github.com/..."
                className="h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[13px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </div>
            <div className="flex flex-col gap-1">
              <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                标题（可选，留空将自动抓取）
              </label>
              <input
                type="text"
                value={urlTitle}
                onChange={(e) => setUrlTitle(e.target.value)}
                placeholder="自定义标题…"
                className="h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[13px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
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
                placeholder="记录你的参考想法…"
                className="p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)] resize-none"
              />
            </div>
          </form>
        )}

        {tab === 'text' && (
          <form onSubmit={handleSubmit} className="flex flex-col gap-3">
            <div className="flex flex-col gap-1">
              <label className="text-[12px] font-medium text-[var(--text-secondary)]">标题</label>
              <input
                type="text"
                autoFocus
                value={textTitle}
                onChange={(e) => setTextTitle(e.target.value)}
                placeholder="例如：排版原则笔记…"
                className="h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[13px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </div>
            <div className="flex flex-col gap-1">
              <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                Markdown / 正文内容
              </label>
              <textarea
                rows={6}
                required
                value={textBody}
                onChange={(e) => setTextBody(e.target.value)}
                placeholder="支持 Markdown 标题、列表、代码块…"
                className="p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)] font-mono"
              />
            </div>
          </form>
        )}

        {tab === 'swatch' && (
          <form onSubmit={handleSubmit} className="flex flex-col gap-3">
            <div className="flex items-center gap-3">
              <input
                type="color"
                value={swatchHex}
                onChange={(e) => setSwatchHex(e.target.value.toUpperCase())}
                className="h-12 w-16 rounded-[var(--radius-settings-inner)] border border-[var(--border-hairline)] cursor-pointer bg-transparent"
              />
              <div className="flex-1 flex flex-col gap-1">
                <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                  色值（HEX）
                </label>
                <input
                  type="text"
                  value={swatchHex}
                  onChange={(e) => setSwatchHex(e.target.value.toUpperCase())}
                  className="h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[13px] charkle-mono text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                />
              </div>
            </div>
            <div className="flex flex-col gap-1">
              <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                色卡名称（可选）
              </label>
              <input
                type="text"
                value={swatchTitle}
                onChange={(e) => setSwatchTitle(e.target.value)}
                placeholder="例如：暖石膏、深海蓝…"
                className="h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[13px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
            </div>
          </form>
        )}
      </div>
    </ModalShell>
  );
};
