import React, { useEffect, useState } from 'react';
import { Copy, Download, ExternalLink, FileText } from 'lucide-react';
import { isMarkdownDocumentAsset, isPlainTextDocumentAsset } from '@charkle/shared';
import type { AssetRecord } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { Button, SegmentedControl } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { MarkdownContentView } from './MarkdownContentView';

export interface DocumentMarkdownViewerProps {
  asset: AssetRecord;
}

export const DocumentMarkdownViewer: React.FC<DocumentMarkdownViewerProps> = ({ asset }) => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const isPdf =
    asset.mimeType === 'application/pdf' || asset.fileName.toLowerCase().endsWith('.pdf');
  const isMarkdown = isMarkdownDocumentAsset(asset);
  const isPlainText = isPlainTextDocumentAsset(asset) || isMarkdown;

  const [mode, setMode] = useState<'rendered' | 'raw'>(isMarkdown ? 'rendered' : 'raw');
  const [content, setContent] = useState<string>(asset.richMetadata?.textExcerpt ?? '');
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    setMode(isMarkdown ? 'rendered' : 'raw');
    if (!isPlainText) return;
    let cancelled = false;
    setLoading(true);
    apiClient
      .getAssetTextContent(asset.id)
      .then((text) => {
        if (!cancelled) {
          setContent(text);
          setLoading(false);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setContent(asset.richMetadata?.textExcerpt ?? asset.ocrText ?? '');
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [asset.id, asset.richMetadata?.textExcerpt, asset.ocrText, isMarkdown, isPlainText]);

  if (isPdf) {
    return (
      <div className="w-[min(900px,90vw)] h-[min(740px,78vh)] rounded-[var(--radius-dock-outer)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl flex flex-col">
        <div className="flex items-center justify-between px-4 py-2.5 border-b border-[var(--border-hairline)] shrink-0">
          <div className="flex items-center gap-2 min-w-0">
            <FileText size={15} className="text-[var(--accent)] shrink-0" />
            <span className="text-[13px] font-semibold text-[var(--text-primary)] truncate">
              {asset.title}
            </span>
          </div>
          <div className="flex items-center gap-1.5">
            <a
              href={apiClient.originalMediaURL(asset.id)}
              target="_blank"
              rel="noopener noreferrer"
              className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[12px] text-[var(--text-primary)]"
            >
              <ExternalLink size={12} />
              新标签打开
            </a>
            <a
              href={apiClient.originalMediaURL(asset.id, true)}
              download={asset.fileName}
              className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[12px] text-[var(--text-primary)]"
            >
              <Download size={12} />
              下载 PDF
            </a>
          </div>
        </div>
        <iframe
          src={apiClient.originalMediaURL(asset.id)}
          title={asset.title}
          className="flex-1 w-full bg-white"
        />
      </div>
    );
  }

  if (isPlainText) {
    return (
      <div className="w-[min(780px,90vw)] h-[min(660px,76vh)] rounded-[var(--radius-dock-outer)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl flex flex-col">
        <div className="flex items-center justify-between gap-3 px-4 py-2.5 border-b border-[var(--border-hairline)] shrink-0">
          <div className="flex items-center gap-2 min-w-0">
            <FileText size={15} className="text-[var(--accent)] shrink-0" />
            <span className="text-[13px] font-semibold text-[var(--text-primary)] truncate">
              {asset.fileName}
            </span>
          </div>

          <div className="flex items-center gap-2 shrink-0">
            {isMarkdown && (
              <SegmentedControl
                ariaLabel="文档视图"
                size="sm"
                value={mode}
                onChange={setMode}
                options={[
                  { id: 'rendered', label: '排版视图' },
                  { id: 'raw', label: '源码' },
                ]}
              />
            )}

            <Button
              variant="secondary"
              size="xs"
              onClick={async () => {
                await navigator.clipboard.writeText(content).catch(() => {});
                pushToast({ tone: 'info', message: '已复制全文内容' });
              }}
            >
              <Copy size={12} />
              复制全文
            </Button>
          </div>
        </div>

        <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-6 select-text">
          {loading ? (
            <div className="py-12 text-center text-[13px] text-[var(--text-secondary)]">
              正在加载文档内容…
            </div>
          ) : mode === 'rendered' && isMarkdown ? (
            <MarkdownContentView markdown={content} />
          ) : (
            <pre className="text-[12.5px] leading-relaxed font-mono whitespace-pre-wrap charkle-wrap-anywhere text-[var(--text-primary)]">
              {content || '（文档为空）'}
            </pre>
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="w-[min(520px,88vw)] p-8 rounded-[var(--radius-dock-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl flex flex-col items-center gap-4 text-center">
      <FileText size={40} className="text-[var(--accent)]" />
      <div>
        <div className="text-[15px] font-semibold text-[var(--text-primary)]">{asset.title}</div>
        <div className="text-[12.5px] text-[var(--text-secondary)] mt-1">{asset.fileName}</div>
      </div>
      <a
        href={apiClient.originalMediaURL(asset.id, true)}
        download={asset.fileName}
        className="charkle-pressable h-9 px-4 inline-flex items-center gap-2 rounded-[var(--radius-dock-inner)] bg-[var(--accent)] text-white text-[13px] font-medium"
      >
        <Download size={14} />
        下载原始文件
      </a>
    </div>
  );
};
