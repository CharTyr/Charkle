import React, { useMemo, useState } from 'react';
import { Copy, ExternalLink, Eye, GitFork, Globe, RefreshCw, Scale, Star } from 'lucide-react';
import { createGitHubMarkdownURLContext } from '@charkle/shared';
import type { AssetRecord, GitHubRepoMetadata } from '@charkle/shared';
import { getGitHubLanguageColor, SegmentedControl } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { MarkdownContentView } from './MarkdownContentView';

export interface GitHubRepoViewerProps {
  asset: AssetRecord;
  repo: GitHubRepoMetadata;
}

export const GitHubRepoViewer: React.FC<GitHubRepoViewerProps> = ({ asset, repo }) => {
  const refreshRichAsset = useLibraryStore((s) => s.refreshRichAsset);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [mode, setMode] = useState<'rendered' | 'raw'>('rendered');
  const [refreshing, setRefreshing] = useState(false);
  const [ogFailed, setOgFailed] = useState(false);

  const urlContext = useMemo(
    () => createGitHubMarkdownURLContext(repo.owner, repo.repo, repo.defaultBranch || 'main'),
    [repo.owner, repo.repo, repo.defaultBranch],
  );

  const handleRefresh = async () => {
    setRefreshing(true);
    try {
      await refreshRichAsset(asset.id);
      setOgFailed(false);
      pushToast({ tone: 'success', message: '已刷新仓库信息' });
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '刷新失败' });
    } finally {
      setRefreshing(false);
    }
  };

  return (
    <div className="w-[min(840px,92vw)] h-[min(720px,80vh)] rounded-[var(--radius-dock-outer)] overflow-hidden bg-[var(--bg-elevated)] text-[var(--text-primary)] border border-[var(--border-hairline)] shadow-2xl flex flex-col">
      {/* Adaptive Light/Dark Studio Header */}
      <div className="p-5 bg-[var(--bg-gallery)]/85 border-b border-[var(--border-hairline)] shrink-0 flex flex-col gap-3">
        <div className="flex items-start justify-between gap-3">
          <div className="flex items-center gap-3 min-w-0">
            {repo.ownerAvatarURL && (
              <img
                src={repo.ownerAvatarURL}
                alt={repo.owner}
                className="h-10 w-10 rounded-full border border-[var(--border-hairline)] shrink-0"
              />
            )}
            <div className="min-w-0">
              <h2 className="text-[16px] font-semibold text-[var(--text-primary)] truncate">
                {repo.fullName}
              </h2>
              {repo.description && (
                <p className="text-[12.5px] text-[var(--text-secondary)] line-clamp-2 mt-0.5">
                  {repo.description}
                </p>
              )}
            </div>
          </div>

          <div className="flex items-center gap-1.5 shrink-0">
            <button
              type="button"
              onClick={() => void handleRefresh()}
              disabled={refreshing}
              title="刷新仓库信息"
              className="charkle-pressable h-8 w-8 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] hover:bg-[var(--border-hairline)] text-[var(--text-primary)] border border-[var(--border-hairline)] flex items-center justify-center cursor-pointer"
            >
              <RefreshCw size={14} className={refreshing ? 'animate-spin' : ''} />
            </button>
            {repo.homepageURL && (
              <a
                href={repo.homepageURL}
                target="_blank"
                rel="noopener noreferrer"
                className="charkle-pressable h-8 px-2.5 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] hover:bg-[var(--border-hairline)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] inline-flex items-center gap-1.5"
              >
                <Globe size={13} />
                主页
              </a>
            )}
            <a
              href={asset.sourceURL || `https://github.com/${repo.fullName}`}
              target="_blank"
              rel="noopener noreferrer"
              className="charkle-pressable h-8 px-3 rounded-[var(--radius-chip)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-[12px] font-medium text-white inline-flex items-center gap-1.5"
            >
              <ExternalLink size={13} />
              在 GitHub 打开
            </a>
          </div>
        </div>

        {/* Stats (Stars, Forks, Watchers) + Language + License Pills */}
        <div className="flex flex-wrap items-center gap-2 text-[12px]">
          <span className="inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[var(--text-primary)] font-medium tabular-nums">
            <Star size={12} className="fill-[#E5A91A] text-[#E5A91A]" />
            {repo.stars.toLocaleString()}
          </span>
          <span className="inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[var(--text-secondary)] tabular-nums">
            <GitFork size={12} />
            {repo.forks.toLocaleString()}
          </span>
          {typeof repo.watchers === 'number' && (
            <span
              title="关注人数"
              className="inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[var(--text-secondary)] tabular-nums"
            >
              <Eye size={12} />
              {repo.watchers.toLocaleString()}
            </span>
          )}
          {repo.language && (
            <span className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[var(--text-primary)]">
              <span
                className="h-2.5 w-2.5 rounded-full"
                style={{ backgroundColor: getGitHubLanguageColor(repo.language) }}
              />
              {repo.language}
            </span>
          )}
          {repo.licenseName && (
            <span className="inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[var(--text-secondary)]">
              <Scale size={12} />
              {repo.licenseName}
            </span>
          )}
        </div>

        {/* Topics */}
        {repo.topics.length > 0 && (
          <div className="flex flex-wrap gap-1.5">
            {repo.topics.slice(0, 12).map((topic) => (
              <span
                key={topic}
                className="px-2 py-0.5 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11px] font-medium"
              >
                {topic}
              </span>
            ))}
          </div>
        )}
      </div>

      {/* README Toolbar */}
      <div className="px-5 py-2 border-b border-[var(--border-hairline)] bg-[var(--bg-elevated)] flex items-center justify-between shrink-0">
        <span className="text-[11.5px] font-mono text-[var(--text-secondary)]">
          README.md ({repo.defaultBranch})
        </span>
        <div className="flex items-center gap-2">
          <SegmentedControl
            ariaLabel="README 视图"
            size="sm"
            value={mode}
            onChange={setMode}
            options={[
              { id: 'rendered', label: '排版视图' },
              { id: 'raw', label: '源码' },
            ]}
          />
          {repo.readmeMarkdown && (
            <button
              type="button"
              onClick={async () => {
                await navigator.clipboard.writeText(repo.readmeMarkdown ?? '').catch(() => {});
                pushToast({ tone: 'info', message: '已复制 README 原文' });
              }}
              className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] hover:bg-[var(--border-hairline)] text-[11.5px] text-[var(--text-primary)] cursor-pointer"
            >
              <Copy size={11.5} />
              复制 README
            </button>
          )}
        </div>
      </div>

      {/* Scrollable OpenGraph Preview Card + README Content */}
      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-6 select-text">
        {repo.openGraphImageURL && !ogFailed && (
          <div className="mb-5 rounded-[var(--radius-settings-outer)] overflow-hidden border border-[var(--border-hairline)] bg-[var(--bg-subtle)]">
            <img
              src={repo.openGraphImageURL}
              alt={`${repo.fullName} preview`}
              loading="lazy"
              onError={() => setOgFailed(true)}
              className="w-full max-h-[240px] object-cover block"
            />
          </div>
        )}

        {!repo.readmeMarkdown ? (
          <div className="py-12 text-center text-[13px] text-[var(--text-secondary)]">
            暂无 README，可点击刷新重试
          </div>
        ) : mode === 'rendered' ? (
          <MarkdownContentView
            markdown={repo.readmeMarkdown}
            urlContext={urlContext}
            emptyText="暂无 README，可点击刷新重试"
          />
        ) : (
          <pre className="text-[12px] font-mono leading-relaxed whitespace-pre-wrap charkle-wrap-anywhere text-[var(--text-primary)]">
            {repo.readmeMarkdown}
          </pre>
        )}
      </div>
    </div>
  );
};
