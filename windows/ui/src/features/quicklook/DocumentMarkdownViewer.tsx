import React, { useEffect, useMemo, useState } from 'react';
import DOMPurify from 'dompurify';
import { marked } from 'marked';
import { Copy, FileText } from 'lucide-react';
import { getTransport } from '../../api/transport';
import { Button } from '../../design-system';
import { useCoordinatorStore } from '../../stores';
import type { AssetRecord } from '../../types/domain';

export interface DocumentMarkdownViewerProps {
  asset: AssetRecord;
}

/**
 * Sanitized Markdown & monospace Code/Text document viewer (marked + DOMPurify).
 */
export const DocumentMarkdownViewer: React.FC<DocumentMarkdownViewerProps> = ({ asset }) => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const [rawText, setRawText] = useState<string>(asset.richMetadata?.textExcerpt ?? '');

  useEffect(() => {
    let cancelled = false;
    setRawText(asset.richMetadata?.textExcerpt ?? '');
    void getTransport()
      .readAssetTextContent(asset.id)
      .then((loaded) => {
        if (!cancelled && loaded != null) {
          setRawText(loaded);
        }
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [asset.id, asset.richMetadata?.textExcerpt]);

  const isMarkdown =
    Boolean(asset.richMetadata?.isMarkdown) ||
    asset.mimeType === 'text/markdown' ||
    /\.mdx?$/i.test(asset.fileName);

  const sanitizedHtml = useMemo(() => {
    if (!isMarkdown || !rawText) return '';
    const html = marked.parse(rawText, { async: false }) as string;
    return DOMPurify.sanitize(html);
  }, [isMarkdown, rawText]);

  return (
    <div
      data-testid="quicklook-document-viewer"
      className="w-full max-w-[820px] max-h-[78vh] mx-auto rounded-[var(--radius-dock-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl flex flex-col overflow-hidden"
    >
      <div className="px-5 py-3 border-b border-[var(--border-hairline)] flex items-center justify-between gap-3 shrink-0">
        <div className="flex items-center gap-2 min-w-0">
          <FileText size={16} className="text-[var(--accent)] shrink-0" />
          <span className="text-[14px] font-semibold text-[var(--text-primary)] truncate">
            {asset.title}
          </span>
          <span className="text-[11.5px] text-[var(--text-tertiary)] truncate">
            {asset.fileName}
          </span>
        </div>
        <Button
          variant="secondary"
          size="xs"
          onClick={() => {
            void navigator.clipboard?.writeText(rawText);
            pushToast({ message: '已复制文档全文', tone: 'success', durationMs: 2200 });
          }}
        >
          <Copy size={12.5} />
          复制全文
        </Button>
      </div>

      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-6">
        {isMarkdown ? (
          <article
            className="text-[14px] leading-[1.7] text-[var(--text-primary)] space-y-3 [&_h1]:text-[22px] [&_h1]:font-semibold [&_h2]:text-[18px] [&_h2]:font-semibold [&_h3]:text-[15px] [&_h3]:font-semibold [&_ul]:list-disc [&_ul]:pl-5 [&_ol]:list-decimal [&_ol]:pl-5 [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:rounded [&_code]:bg-[var(--bg-subtle)] [&_pre]:p-3.5 [&_pre]:rounded-[var(--radius-settings-inner)] [&_pre]:bg-[var(--bg-subtle)] [&_pre]:overflow-x-auto [&_a]:text-[var(--accent)] [&_a]:underline"
            dangerouslySetInnerHTML={{ __html: sanitizedHtml }}
          />
        ) : (
          <pre className="text-[12.5px] leading-[1.6] text-[var(--text-primary)] whitespace-pre-wrap break-words charkle-mono">
            {rawText || '暂无可显示的文本内容'}
          </pre>
        )}
      </div>
    </div>
  );
};
