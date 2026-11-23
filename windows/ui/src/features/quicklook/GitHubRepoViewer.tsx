import React, { useMemo, useState } from 'react';
import DOMPurify from 'dompurify';
import { marked } from 'marked';
import { Code2, ExternalLink, GitFork, RefreshCw, Star } from 'lucide-react';
import { getTransport } from '../../api/transport';
import { Button, getGitHubLanguageColor } from '../../design-system';
import { useLibraryStore } from '../../stores';
import type { AssetRecord } from '../../types/domain';

export interface GitHubRepoViewerProps {
  asset: AssetRecord;
}

export const GitHubRepoViewer: React.FC<GitHubRepoViewerProps> = ({ asset }) => {
  const repo = asset.richMetadata?.githubRepo;
  const refreshRichAsset = useLibraryStore((s) => s.refreshRichAsset);
  const [refreshing, setRefreshing] = useState(false);

  const readmeHtml = useMemo(() => {
    const md = repo?.readmeMarkdown;
    if (!md) return '';
    const raw = marked.parse(md, { async: false }) as string;
    return DOMPurify.sanitize(raw);
  }, [repo?.readmeMarkdown]);

  if (!repo) return null;

  return (
    <div
      data-testid="quicklook-github-viewer"
      className="w-full max-w-[860px] max-h-[80vh] mx-auto rounded-[var(--radius-dock-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl flex flex-col overflow-hidden"
    >
      <div className="p-5 border-b border-[var(--border-hairline)] flex flex-col gap-3 shrink-0">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="flex items-center gap-1.5 text-[12px] text-[var(--text-secondary)]">
              <Code2 size={14} />
              <span>{repo.owner}</span>
            </div>
            <h2 className="text-[20px] font-semibold text-[var(--text-primary)] tracking-[-0.015em] mt-0.5 truncate">
              {repo.fullName}
            </h2>
          </div>

          <div className="flex items-center gap-1.5 shrink-0">
            <Button
              variant="secondary"
              size="xs"
              loading={refreshing}
              onClick={async () => {
                setRefreshing(true);
                try {
                  await refreshRichAsset(asset.id);
                } finally {
                  setRefreshing(false);
                }
              }}
            >
              <RefreshCw size={12.5} />
              刷新
            </Button>
            {asset.sourceURL && (
              <Button
                variant="primary"
                size="xs"
                onClick={() => void getTransport().openExternalUrl(asset.sourceURL!)}
              >
                <ExternalLink size={12.5} />
                打开 GitHub
              </Button>
            )}
          </div>
        </div>

        {repo.description && (
          <p className="text-[13.5px] text-[var(--text-secondary)] leading-relaxed charkle-prose">
            {repo.description}
          </p>
        )}

        <div className="flex items-center gap-4 flex-wrap text-[12px] text-[var(--text-secondary)] charkle-tabular">
          <span className="inline-flex items-center gap-1">
            <Star size={13} className="text-amber-500 fill-amber-500" />
            {repo.stars.toLocaleString()}
          </span>
          <span className="inline-flex items-center gap-1">
            <GitFork size={13} />
            {repo.forks.toLocaleString()}
          </span>
          {repo.language && (
            <span className="inline-flex items-center gap-1.5">
              <span
                className="h-2.5 w-2.5 rounded-full"
                style={{ backgroundColor: getGitHubLanguageColor(repo.language) }}
              />
              {repo.language}
            </span>
          )}
          {repo.license && <span>{repo.license}</span>}
        </div>

        {repo.topics.length > 0 && (
          <div className="flex flex-wrap gap-1.5">
            {repo.topics.map((topic) => (
              <span
                key={topic}
                className="px-2 py-0.5 text-[11px] rounded-full bg-[var(--accent-soft)] text-[var(--accent)]"
              >
                {topic}
              </span>
            ))}
          </div>
        )}
      </div>

      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-6">
        {readmeHtml ? (
          <article
            className="text-[13.5px] leading-[1.7] text-[var(--text-primary)] space-y-3 [&_h1]:text-[20px] [&_h1]:font-semibold [&_h2]:text-[16.5px] [&_h2]:font-semibold [&_ul]:list-disc [&_ul]:pl-5 [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:rounded [&_code]:bg-[var(--bg-subtle)] [&_pre]:p-3 [&_pre]:rounded-[var(--radius-settings-inner)] [&_pre]:bg-[var(--bg-subtle)] [&_pre]:overflow-x-auto [&_a]:text-[var(--accent)] [&_a]:underline"
            dangerouslySetInnerHTML={{ __html: readmeHtml }}
          />
        ) : (
          <div className="py-8 text-center text-[12.5px] text-[var(--text-tertiary)]">
            尚未缓存 README 内容，点击右上角「刷新」可重新拉取。
          </div>
        )}
      </div>
    </div>
  );
};
