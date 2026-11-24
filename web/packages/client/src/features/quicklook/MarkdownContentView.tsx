import React, { useMemo, useRef, useState } from 'react';
import DOMPurify from 'dompurify';
import { marked } from 'marked';
import {
  AlertCircle,
  AlertTriangle,
  Check,
  ChevronRight,
  Copy,
  Info,
  Lightbulb,
  ListTree,
  OctagonAlert,
} from 'lucide-react';
import {
  MARKDOWN_ALERT_LABELS,
  parseMarkdownDocument,
  resolveMarkdownAssetURL,
  resolveMarkdownLinkURL,
} from '@charkle/shared';
import type {
  MarkdownAlertKind,
  MarkdownAlignment,
  MarkdownBlock,
  MarkdownURLContext,
} from '@charkle/shared';
import { prefersReducedMotion } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';

export interface MarkdownContentViewProps {
  markdown: string;
  urlContext?: MarkdownURLContext;
  showTocToggle?: boolean;
  emptyText?: string;
}

const ALERT_ICON: Record<MarkdownAlertKind, React.ReactNode> = {
  note: <Info size={14} />,
  tip: <Lightbulb size={14} />,
  important: <AlertCircle size={14} />,
  warning: <AlertTriangle size={14} />,
  caution: <OctagonAlert size={14} />,
};

function alignmentClass(align: MarkdownAlignment): string {
  if (align === 'center') return 'text-center';
  if (align === 'trailing') return 'text-right';
  return 'text-left';
}

function renderSafeInlineHtml(text: string, urlContext?: MarkdownURLContext): string {
  const rawHtml = marked.parseInline(text, { async: false, gfm: true }) as string;
  const clean = DOMPurify.sanitize(rawHtml, {
    ADD_ATTR: ['target', 'rel'],
  });
  if (typeof document === 'undefined') return clean;

  const tpl = document.createElement('template');
  tpl.innerHTML = clean;

  tpl.content.querySelectorAll('a[href]').forEach((el) => {
    const rawHref = el.getAttribute('href') || '';
    const resolved = resolveMarkdownLinkURL(rawHref, urlContext);
    el.setAttribute('href', resolved);
    if (!resolved.startsWith('#')) {
      el.setAttribute('target', '_blank');
      el.setAttribute('rel', 'noopener noreferrer');
    }
  });

  tpl.content.querySelectorAll('img[src]').forEach((el) => {
    const rawSrc = el.getAttribute('src') || '';
    const resolved = resolveMarkdownAssetURL(rawSrc, urlContext);
    el.setAttribute('src', resolved);
    el.setAttribute('loading', 'lazy');
  });

  return tpl.innerHTML;
}

const InlineMarkdown: React.FC<{
  text: string;
  urlContext?: MarkdownURLContext;
  className?: string;
}> = ({ text, urlContext, className }) => {
  const html = useMemo(() => renderSafeInlineHtml(text, urlContext), [text, urlContext]);
  return <span className={className} dangerouslySetInnerHTML={{ __html: html }} />;
};

const CodeBlockView: React.FC<{ language: string; content: string }> = ({ language, content }) => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const [copied, setCopied] = useState(false);

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(content);
      setCopied(true);
      pushToast({ tone: 'info', message: '已复制代码块' });
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      pushToast({ tone: 'error', message: '复制失败' });
    }
  };

  return (
    <div className="charkle-code-block">
      <div className="charkle-code-block-header">
        <span className="font-mono uppercase tracking-wide text-[10.5px]">
          {language || 'code'}
        </span>
        <button
          type="button"
          onClick={() => void handleCopy()}
          className="charkle-code-copy-btn"
        >
          {copied ? <Check size={11.5} /> : <Copy size={11.5} />}
          <span>{copied ? '已复制' : '复制'}</span>
        </button>
      </div>
      <pre>
        <code>{content}</code>
      </pre>
    </div>
  );
};

interface GroupedList {
  kind: 'listGroup';
  id: number;
  ordered: boolean;
  items: Array<Extract<MarkdownBlock, { type: 'listItem' }>>;
}

type RenderNode = MarkdownBlock | GroupedList;

function groupConsecutiveListItems(blocks: readonly MarkdownBlock[]): RenderNode[] {
  const out: RenderNode[] = [];
  let i = 0;
  while (i < blocks.length) {
    const b = blocks[i];
    if (b.type === 'listItem') {
      const ordered = b.marker.type === 'ordered';
      const items: Array<Extract<MarkdownBlock, { type: 'listItem' }>> = [b];
      i++;
      while (i < blocks.length && blocks[i].type === 'listItem') {
        const nextItem = blocks[i] as Extract<MarkdownBlock, { type: 'listItem' }>;
        if ((nextItem.marker.type === 'ordered') !== ordered) break;
        items.push(nextItem);
        i++;
      }
      out.push({ kind: 'listGroup', id: b.id, ordered, items });
    } else {
      out.push(b);
      i++;
    }
  }
  return out;
}

const MarkdownBlocksView: React.FC<{
  blocks: readonly MarkdownBlock[];
  urlContext?: MarkdownURLContext;
}> = ({ blocks, urlContext }) => {
  const nodes = useMemo(() => groupConsecutiveListItems(blocks), [blocks]);

  return (
    <>
      {nodes.map((node) => {
        if ('kind' in node && node.kind === 'listGroup') {
          const ListTag = node.ordered ? 'ol' : 'ul';
          const isTaskList = node.items.every((it) => it.marker.type === 'task');
          return (
            <ListTag
              key={`list-${node.id}`}
              className={isTaskList ? '!list-none !pl-1' : undefined}
            >
              {node.items.map((item) => (
                <li
                  key={item.id}
                  style={item.indent > 0 ? { marginLeft: `${item.indent * 18}px` } : undefined}
                >
                  {item.marker.type === 'task' && (
                    <input type="checkbox" checked={item.marker.checked} readOnly />
                  )}
                  <InlineMarkdown text={item.text} urlContext={urlContext} />
                </li>
              ))}
            </ListTag>
          );
        }

        const block = node as MarkdownBlock;
        switch (block.type) {
          case 'heading': {
            const level = Math.max(1, Math.min(6, block.level));
            const props = {
              'data-md-slug': block.slug,
              className: alignmentClass(block.alignment),
            };
            const inner = <InlineMarkdown text={block.text} urlContext={urlContext} />;
            if (level === 1) return <h1 key={block.id} {...props}>{inner}</h1>;
            if (level === 2) return <h2 key={block.id} {...props}>{inner}</h2>;
            if (level === 3) return <h3 key={block.id} {...props}>{inner}</h3>;
            if (level === 4) return <h4 key={block.id} {...props}>{inner}</h4>;
            if (level === 5) return <h5 key={block.id} {...props}>{inner}</h5>;
            return <h6 key={block.id} {...props}>{inner}</h6>;
          }

          case 'paragraph':
            return (
              <p key={block.id} className={alignmentClass(block.alignment)}>
                <InlineMarkdown text={block.text} urlContext={urlContext} />
              </p>
            );

          case 'code':
            return <CodeBlockView key={block.id} language={block.language} content={block.content} />;

          case 'quote': {
            if (block.alertKind) {
              return (
                <div
                  key={block.id}
                  className={`charkle-callout charkle-callout-${block.alertKind}`}
                >
                  <div className="charkle-callout-title">
                    {ALERT_ICON[block.alertKind]}
                    <span>{MARKDOWN_ALERT_LABELS[block.alertKind]}</span>
                  </div>
                  {block.text && (
                    <div className="charkle-callout-body">
                      {block.text.split(/\n{2,}/).map((para, idx) => (
                        <p key={idx}>
                          <InlineMarkdown text={para} urlContext={urlContext} />
                        </p>
                      ))}
                    </div>
                  )}
                </div>
              );
            }
            return (
              <blockquote key={block.id}>
                {block.text.split(/\n{2,}/).map((para, idx) => (
                  <p key={idx}>
                    <InlineMarkdown text={para} urlContext={urlContext} />
                  </p>
                ))}
              </blockquote>
            );
          }

          case 'table':
            return (
              <table key={block.id}>
                <thead>
                  <tr>
                    {block.headers.map((header, idx) => (
                      <th key={idx} className={alignmentClass(block.alignments[idx] ?? 'leading')}>
                        <InlineMarkdown text={header} urlContext={urlContext} />
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {block.rows.map((row, rIdx) => (
                    <tr key={rIdx}>
                      {row.map((cell, cIdx) => (
                        <td
                          key={cIdx}
                          className={alignmentClass(block.alignments[cIdx] ?? 'leading')}
                        >
                          <InlineMarkdown text={cell} urlContext={urlContext} />
                        </td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            );

          case 'image': {
            const imgEl = (
              <img
                src={block.item.url}
                alt={block.item.alt}
                width={block.item.width ?? undefined}
                height={block.item.height ?? undefined}
                loading="lazy"
              />
            );
            return (
              <div key={block.id} className={`my-2 ${alignmentClass(block.alignment)}`}>
                {block.item.linkURL ? (
                  <a
                    href={block.item.linkURL}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-block"
                  >
                    {imgEl}
                  </a>
                ) : (
                  imgEl
                )}
              </div>
            );
          }

          case 'imageRow':
            return (
              <div
                key={block.id}
                className={[
                  'my-2 flex flex-wrap items-center gap-2',
                  block.alignment === 'center'
                    ? 'justify-center'
                    : block.alignment === 'trailing'
                      ? 'justify-end'
                      : 'justify-start',
                ].join(' ')}
              >
                {block.items.map((item) => {
                  const imgEl = (
                    <img
                      src={item.url}
                      alt={item.alt}
                      width={item.width ?? undefined}
                      height={item.height ?? undefined}
                      loading="lazy"
                      className="!my-0"
                    />
                  );
                  return item.linkURL ? (
                    <a
                      key={item.id}
                      href={item.linkURL}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="inline-flex"
                    >
                      {imgEl}
                    </a>
                  ) : (
                    <React.Fragment key={item.id}>{imgEl}</React.Fragment>
                  );
                })}
              </div>
            );

          case 'details':
            return (
              <details key={block.id}>
                <summary>{block.summary || '展开详情'}</summary>
                <div className="mt-2">
                  <MarkdownBlocksView blocks={block.children} urlContext={urlContext} />
                </div>
              </details>
            );

          case 'divider':
            return <hr key={block.id} />;

          default:
            return null;
        }
      })}
    </>
  );
};

export const MarkdownContentView: React.FC<MarkdownContentViewProps> = ({
  markdown,
  urlContext,
  showTocToggle = true,
  emptyText = '（文档为空）',
}) => {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const [tocOpen, setTocOpen] = useState(false);

  const parsed = useMemo(
    () => parseMarkdownDocument(markdown, urlContext),
    [markdown, urlContext],
  );

  const hasToc = showTocToggle && parsed.toc.length >= 2;

  const jumpToSlug = (slug: string) => {
    const host = rootRef.current;
    if (!host) return;
    const safeSlug =
      typeof CSS !== 'undefined' && typeof CSS.escape === 'function'
        ? CSS.escape(slug)
        : slug.replace(/"/g, '\\"');
    const target = host.querySelector<HTMLElement>(`[data-md-slug="${safeSlug}"]`);
    target?.scrollIntoView({
      behavior: prefersReducedMotion() ? 'auto' : 'smooth',
      block: 'start',
    });
  };

  if (!markdown.trim()) {
    return (
      <div className="py-12 text-center text-[13px] text-[var(--text-secondary)]">
        {emptyText}
      </div>
    );
  }

  return (
    <div ref={rootRef} className="flex flex-col gap-4">
      {/* Optional Frontmatter Chips */}
      {parsed.frontmatterEntries.length > 0 && (
        <div className="flex flex-wrap items-center gap-1.5 pb-3 border-b border-[var(--border-hairline)]">
          {parsed.frontmatterEntries.slice(0, 8).map((entry) => (
            <span
              key={entry.key}
              className="inline-flex items-center gap-1 px-2 py-0.5 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[11.5px] text-[var(--text-secondary)]"
            >
              <span className="font-medium text-[var(--text-tertiary)]">{entry.key}:</span>
              <span className="text-[var(--text-primary)]">{entry.value}</span>
            </span>
          ))}
        </div>
      )}

      {/* Optional Collapsible Heading Table of Contents */}
      {hasToc && (
        <div className="rounded-[var(--radius-settings-inner)] border border-[var(--border-hairline)] bg-[var(--bg-gallery)]/75 overflow-hidden">
          <button
            type="button"
            aria-expanded={tocOpen}
            onClick={() => setTocOpen((v) => !v)}
            className="w-full px-3 py-2 flex items-center justify-between gap-2 text-[12px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/70 cursor-pointer text-left"
          >
            <span className="inline-flex items-center gap-1.5">
              <ListTree size={13.5} className="text-[var(--accent)]" />
              <span>目录</span>
              <span className="text-[11px] tabular-nums text-[var(--text-tertiary)]">
                ({parsed.toc.length})
              </span>
            </span>
            <ChevronRight
              size={13}
              className="transition-transform duration-[var(--duration-sm)] ease-[var(--ease-out-strong)]"
              style={{ transform: tocOpen ? 'rotate(90deg)' : 'rotate(0deg)' }}
            />
          </button>

          {tocOpen && (
            <nav
              aria-label="文档目录"
              className="px-2 pb-2 pt-1 border-t border-[var(--border-hairline)] flex flex-col gap-0.5 max-h-[200px] overflow-y-auto charkle-scroll"
            >
              {parsed.toc.map((item) => (
                <button
                  key={`${item.id}-${item.slug}`}
                  type="button"
                  onClick={() => jumpToSlug(item.slug)}
                  style={{ paddingLeft: `${8 + Math.max(0, item.level - 1) * 12}px` }}
                  className="w-full py-1 pr-2 rounded-[6px] text-left text-[12px] text-[var(--text-secondary)] hover:text-[var(--accent)] hover:bg-[var(--bg-subtle)] truncate cursor-pointer"
                >
                  {item.text}
                </button>
              ))}
            </nav>
          )}
        </div>
      )}

      {/* Styled GFM Markdown Article */}
      <article className="charkle-markdown">
        <MarkdownBlocksView blocks={parsed.blocks} urlContext={urlContext} />
      </article>
    </div>
  );
};
