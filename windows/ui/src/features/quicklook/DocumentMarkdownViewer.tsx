import React, { useEffect, useMemo, useState } from 'react';
import DOMPurify from 'dompurify';
import { marked } from 'marked';
import { Copy16Regular } from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import { Button } from '../../design-system';
import { useCoordinatorStore } from '../../stores';
import type { AssetRecord } from '../../types/domain';

export interface DocumentMarkdownViewerProps {
  asset: AssetRecord;
}

function extensionBadge(fileName: string): string {
  const parts = fileName.split('.');
  const ext = parts.length > 1 ? parts[parts.length - 1].trim().toUpperCase() : '';
  return ext && ext.length <= 6 ? ext : 'TXT';
}

/**
 * Markdown & plain text reader card (1:1 macOS `QuickLookMarkdownReaderCard`):
 * - File extension mono badge + rendered / raw source toggle for Markdown + Copy All
 * - Intercepts anchor clicks to open externally rather than navigating the app webview
 */
export const DocumentMarkdownViewer: React.FC<DocumentMarkdownViewerProps> = ({ asset }) => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const [rawText, setRawText] = useState<string>(asset.richMetadata?.textExcerpt ?? '');
  const [showRawSource, setShowRawSource] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setShowRawSource(false);
    setRawText(asset.richMetadata?.textExcerpt ?? asset.notes ?? asset.ocrText ?? '');
    void getTransport()
      .readAssetTextContent(asset.id)
      .then((loaded) => {
        if (!cancelled && loaded != null && loaded.trim().length > 0) {
          setRawText(loaded);
        }
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [asset.id, asset.richMetadata?.textExcerpt, asset.notes, asset.ocrText]);

  const isMarkdown =
    Boolean(asset.richMetadata?.isMarkdown) ||
    asset.mimeType === 'text/markdown' ||
    /\.(md|markdown|mdx)$/i.test(asset.fileName);

  const sanitizedHtml = useMemo(() => {
    if (!isMarkdown || !rawText) return '';
    const html = marked.parse(rawText, { async: false, gfm: true }) as string;
    return DOMPurify.sanitize(html, {
      FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form'],
      FORBID_ATTR: ['onerror', 'onload', 'onclick', 'onmouseover'],
    });
  }, [isMarkdown, rawText]);

  const handleLinkClick = (e: React.MouseEvent<HTMLElement>) => {
    const anchor = (e.target as HTMLElement).closest('a[href]') as HTMLAnchorElement | null;
    if (!anchor) return;
    const href = anchor.getAttribute('href')?.trim();
    if (!href) return;
    e.preventDefault();
    if (/^https?:\/\//i.test(href)) {
      void getTransport()
        .openExternalUrl(href)
        .catch(() => {
          pushToast({ message: '无法在默认浏览器中打开链接', tone: 'error' });
        });
    }
  };

  return (
    <div
      data-testid="quicklook-document-viewer"
      onClick={(e) => e.stopPropagation()}
      className="w-full max-w-[740px] max-h-[78vh] mx-auto rounded-[var(--win-radius-dialog)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-flyout)] shadow-[0_24px_60px_rgba(0,0,0,0.40)] flex flex-col overflow-hidden"
    >
      <div className="px-6 py-4 border-b border-[var(--win-stroke-divider)] flex items-center justify-between gap-3 shrink-0">
        <div className="flex items-center gap-2.5 min-w-0">
          <span className="px-2 py-1 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)] text-[11px] font-bold charkle-mono text-[var(--text-primary)] shrink-0">
            {extensionBadge(asset.fileName)}
          </span>
          <span className="text-[16px] font-semibold text-[var(--text-primary)] truncate">
            {asset.title}
          </span>
        </div>

        <div className="flex items-center gap-2 shrink-0">
          {isMarkdown && (
            <Button
              variant="standard"
              size="xs"
              onClick={() => setShowRawSource((v) => !v)}
            >
              {showRawSource ? '渲染视图' : '查看原文'}
            </Button>
          )}
          <Button
            variant="standard"
            size="xs"
            onClick={() => {
              if (!navigator.clipboard?.writeText) {
                pushToast({ message: '当前环境不支持直接写入剪贴板', tone: 'error' });
                return;
              }
              void navigator.clipboard
                .writeText(rawText)
                .then(() => {
                  pushToast({ message: '已复制文档全文', tone: 'success', durationMs: 2200 });
                })
                .catch(() => {
                  pushToast({ message: '无法写入系统剪贴板', tone: 'error' });
                });
            }}
          >
            <Copy16Regular className="w-3.5 h-3.5" />
            复制全文
          </Button>
        </div>
      </div>

      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-6">
        {isMarkdown && !showRawSource ? (
          <article
            onClick={handleLinkClick}
            className="text-[14px] leading-[1.7] text-[var(--text-primary)] select-text space-y-3 [&_h1]:text-[22px] [&_h1]:font-bold [&_h1]:pb-1.5 [&_h1]:border-b [&_h1]:border-[var(--border-hairline)] [&_h2]:text-[17.5px] [&_h2]:font-bold [&_h2]:pb-1 [&_h2]:border-b [&_h2]:border-[var(--border-hairline)] [&_h3]:text-[15px] [&_h3]:font-semibold [&_ul]:list-disc [&_ul]:pl-5 [&_ol]:list-decimal [&_ol]:pl-5 [&_blockquote]:border-l-[3px] [&_blockquote]:border-[var(--accent)]/60 [&_blockquote]:pl-3 [&_blockquote]:text-[var(--text-secondary)] [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:rounded [&_code]:bg-[var(--bg-subtle)] [&_pre]:p-3.5 [&_pre]:rounded-[10px] [&_pre]:bg-[var(--bg-subtle)] [&_pre]:overflow-x-auto [&_pre_code]:bg-transparent [&_pre_code]:p-0 [&_table]:w-full [&_table]:border-collapse [&_th]:text-left [&_th]:px-2.5 [&_th]:py-1.5 [&_th]:bg-[var(--bg-subtle)] [&_th]:border [&_th]:border-[var(--border-hairline)] [&_td]:px-2.5 [&_td]:py-1.5 [&_td]:border [&_td]:border-[var(--border-hairline)] [&_a]:text-[var(--accent)] [&_a]:underline"
            dangerouslySetInnerHTML={{ __html: sanitizedHtml }}
          />
        ) : (
          <pre
            className={[
              'text-[var(--text-primary)] whitespace-pre-wrap break-words select-text',
              showRawSource ? 'text-[12.5px] leading-[1.6] charkle-mono' : 'text-[14px] leading-[1.65]',
            ].join(' ')}
          >
            {rawText || '暂无可预览正文'}
          </pre>
        )}
      </div>
    </div>
  );
};
