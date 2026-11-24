import React, { useEffect, useMemo, useState } from 'react';
import DOMPurify from 'dompurify';
import { marked } from 'marked';
import { ExternalLink, RefreshCw } from 'lucide-react';
import { getTransport } from '../../api/transport';
import { getGitHubLanguageColor } from '../../design-system';
import { useCoordinatorStore, useLibraryStore } from '../../stores';
import type { AssetRecord } from '../../types/domain';

export interface GitHubRepoViewerProps {
  asset: AssetRecord;
}

function isBlockedProtocol(href: string): boolean {
  const trimmed = href.trim();
  const schemeMatch = trimmed.match(/^([a-z][a-z0-9+.-]*):/i);
  if (!schemeMatch) return false;
  const scheme = schemeMatch[1].toLowerCase();
  return scheme !== 'http' && scheme !== 'https' && scheme !== 'mailto';
}

export const GitHubRepoViewer: React.FC<GitHubRepoViewerProps> = ({ asset }) => {
  const repo = asset.richMetadata?.githubRepo;
  const refreshRichAsset = useLibraryStore((s) => s.refreshRichAsset);
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const [refreshing, setRefreshing] = useState(false);
  const [avatarFailed, setAvatarFailed] = useState(false);
  const [ogFailed, setOgFailed] = useState(false);

  useEffect(() => {
    setAvatarFailed(false);
    setOgFailed(false);
    setRefreshing(false);
  }, [asset.id]);

  const readmeHtml = useMemo(() => {
    const md = repo?.readmeMarkdown;
    if (!md) return '';
    const raw = marked.parse(md, { async: false, gfm: true }) as string;
    return DOMPurify.sanitize(raw, {
      FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form'],
      FORBID_ATTR: ['onerror', 'onload', 'onclick', 'onmouseover'],
    });
  }, [repo?.readmeMarkdown]);

  if (!repo) return null;

  const avatarUrl = repo.avatarURL || repo.ownerAvatarURL || null;
  const repoUrl = asset.sourceURL || `https://github.com/${repo.fullName}`;
  const ogUrl =
    repo.openGraphImageURL ||
    `https://opengraph.githubassets.com/1/${repo.owner}/${repo.repo}`;

  const openSafeExternal = (url: string) => {
    if (isBlockedProtocol(url)) return;
    void getTransport()
      .openExternalUrl(url)
      .catch(() => {
        pushToast({ message: '无法在默认浏览器中打开链接', tone: 'error' });
      });
  };

  const handleArticleClick = (e: React.MouseEvent<HTMLElement>) => {
    const anchor = (e.target as HTMLElement).closest('a[href]') as HTMLAnchorElement | null;
    if (!anchor) return;
    const href = anchor.getAttribute('href')?.trim();
    if (!href) return;
    e.preventDefault();
    if (href.startsWith('#') || isBlockedProtocol(href)) return;
    const resolved = /^https?:\/\//i.test(href)
      ? href
      : /^mailto:/i.test(href)
        ? href
        : `https://github.com/${repo.owner}/${repo.repo}/blob/${repo.defaultBranch || 'main'}/${href.replace(/^\/+/, '')}`;
    openSafeExternal(resolved);
  };

  return (
    <div
      data-testid="quicklook-github-viewer"
      onClick={(e) => e.stopPropagation()}
      className="w-full max-w-[760px] max-h-[82vh] mx-auto rounded-[18px] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-[0_24px_60px_rgba(0,0,0,0.42)] flex flex-col overflow-hidden"
    >
      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-6 flex flex-col gap-4">
        {/* Header: Owner Avatar + owner / repo + Actions (1:1 macOS QuickLookGitHubRepoCard) */}
        <div className="flex items-center gap-3">
          {avatarUrl && !avatarFailed ? (
            <img
              src={avatarUrl}
              alt={repo.owner}
              onError={() => setAvatarFailed(true)}
              className="w-9 h-9 rounded-[8px] object-cover shrink-0 bg-[var(--bg-subtle)]"
            />
          ) : (
            <div className="w-9 h-9 rounded-[8px] bg-[var(--accent-soft)] text-[var(--accent)] flex items-center justify-center text-[16px] font-bold shrink-0">
              {repo.owner.slice(0, 1).toUpperCase()}
            </div>
          )}

          <div className="flex items-center gap-1 text-[18px] font-bold min-w-0 truncate">
            <span className="text-[var(--text-secondary)] truncate">{repo.owner}</span>
            <span className="text-[var(--text-tertiary)]">/</span>
            <span className="text-[var(--text-primary)] truncate">{repo.repo}</span>
          </div>

          <span className="flex-1" />

          <button
            type="button"
            disabled={refreshing}
            title="重新同步仓库星标与 README"
            onClick={async () => {
              setRefreshing(true);
              try {
                await refreshRichAsset(asset.id);
              } catch (err) {
                pushToast({
                  message: `刷新失败：${err instanceof Error ? err.message : String(err)}`,
                  tone: 'error',
                });
              } finally {
                setRefreshing(false);
              }
            }}
            className="charkle-pressable w-7 h-7 rounded-full bg-[var(--bg-subtle)] hover:bg-[var(--border-hairline)] text-[var(--text-primary)] inline-flex items-center justify-center shrink-0 cursor-pointer disabled:opacity-50"
          >
            <RefreshCw size={12} className={refreshing ? 'animate-spin' : ''} />
          </button>

          <button
            type="button"
            onClick={() => openSafeExternal(repoUrl)}
            className="charkle-pressable inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-[var(--bg-subtle)] hover:bg-[var(--border-hairline)] text-[12px] font-semibold text-[var(--text-primary)] shrink-0 cursor-pointer"
          >
            <ExternalLink size={12} />
            <span>GitHub</span>
          </button>
        </div>

        {/* Description */}
        {repo.description && (
          <p className="text-[14px] leading-relaxed text-[var(--text-primary)]/88 select-text charkle-prose">
            {repo.description}
          </p>
        )}

        {/* Language + Homepage + License */}
        {(repo.language || repo.homepageURL || repo.license) && (
          <div className="flex items-center gap-2.5 flex-wrap text-[12.5px] text-[var(--text-secondary)]">
            {repo.language && (
              <span className="inline-flex items-center gap-1.5 font-medium">
                <span
                  className="h-2.5 w-2.5 rounded-full shrink-0"
                  style={{ backgroundColor: getGitHubLanguageColor(repo.language) }}
                />
                {repo.language}
              </span>
            )}
            {repo.homepageURL && (
              <>
                {repo.language && <span className="text-[var(--text-tertiary)]">·</span>}
                <button
                  type="button"
                  onClick={() =>
                    openSafeExternal(
                      /^https?:\/\//i.test(repo.homepageURL!)
                        ? repo.homepageURL!
                        : `https://${repo.homepageURL}`,
                    )
                  }
                  className="font-medium text-[var(--accent)] hover:underline truncate max-w-[260px] cursor-pointer"
                >
                  {repo.homepageURL.replace(/^https?:\/\//i, '')}
                </button>
              </>
            )}
            {repo.license && (
              <>
                {(repo.language || repo.homepageURL) && (
                  <span className="text-[var(--text-tertiary)]">·</span>
                )}
                <span className="text-[12px] charkle-mono">{repo.license}</span>
              </>
            )}
          </div>
        )}

        {/* Stars & Forks */}
        <div className="flex items-center gap-4 text-[13px] charkle-tabular">
          <span className="inline-flex items-baseline gap-1">
            <strong className="font-bold text-[var(--text-primary)]">
              {repo.stars.toLocaleString()}
            </strong>
            <span className="text-[12.5px] text-[var(--text-secondary)]">stars</span>
          </span>
          <span className="inline-flex items-baseline gap-1">
            <strong className="font-bold text-[var(--text-primary)]">
              {repo.forks.toLocaleString()}
            </strong>
            <span className="text-[12.5px] text-[var(--text-secondary)]">forks</span>
          </span>
        </div>

        {/* Topics */}
        {repo.topics.length > 0 && (
          <div className="flex flex-wrap gap-1.5">
            {repo.topics.map((topic) => (
              <span
                key={topic}
                className="px-2.5 py-1 text-[11.5px] font-medium rounded-full bg-[var(--accent-soft)] text-[var(--accent)]"
              >
                {topic}
              </span>
            ))}
          </div>
        )}

        {/* OpenGraph Preview Card */}
        {ogUrl && !ogFailed && (
          <img
            src={ogUrl}
            alt={repo.fullName}
            loading="lazy"
            onError={() => setOgFailed(true)}
            className="w-full rounded-[12px] border border-[var(--border-hairline)] object-contain"
          />
        )}

        <div className="h-px bg-[var(--border-hairline)]" />

        {/* README Section */}
        <div className="flex flex-col gap-3">
          <div className="text-[11px] font-bold tracking-[0.08em] charkle-mono text-[var(--text-secondary)]">
            README
          </div>

          {readmeHtml ? (
            <article
              onClick={handleArticleClick}
              className="text-[13.5px] leading-[1.7] text-[var(--text-primary)] select-text space-y-3 [&_h1]:text-[21px] [&_h1]:font-bold [&_h1]:pb-1.5 [&_h1]:border-b [&_h1]:border-[var(--border-hairline)] [&_h2]:text-[17px] [&_h2]:font-bold [&_h2]:pb-1 [&_h2]:border-b [&_h2]:border-[var(--border-hairline)] [&_h3]:text-[15px] [&_h3]:font-semibold [&_ul]:list-disc [&_ul]:pl-5 [&_ol]:list-decimal [&_ol]:pl-5 [&_blockquote]:border-l-[3px] [&_blockquote]:border-[var(--accent)]/60 [&_blockquote]:pl-3 [&_blockquote]:text-[var(--text-secondary)] [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:rounded [&_code]:bg-[var(--bg-subtle)] [&_code]:text-[12px] [&_pre]:p-3 [&_pre]:rounded-[10px] [&_pre]:bg-[var(--bg-subtle)] [&_pre]:overflow-x-auto [&_pre_code]:bg-transparent [&_pre_code]:p-0 [&_table]:w-full [&_table]:border-collapse [&_th]:text-left [&_th]:px-2.5 [&_th]:py-1.5 [&_th]:bg-[var(--bg-subtle)] [&_th]:border [&_th]:border-[var(--border-hairline)] [&_td]:px-2.5 [&_td]:py-1.5 [&_td]:border [&_td]:border-[var(--border-hairline)] [&_img]:max-w-full [&_img]:rounded-[10px] [&_a]:text-[var(--accent)] [&_a]:underline"
              dangerouslySetInnerHTML={{ __html: readmeHtml }}
            />
          ) : (
            <div className="py-6 text-[13px] text-[var(--text-secondary)]">
              暂未拉取到 README 内容，可点击右上角刷新重试或前往 GitHub 查看。
            </div>
          )}
        </div>
      </div>
    </div>
  );
};
