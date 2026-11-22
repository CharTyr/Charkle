import React, { useMemo, useState } from 'react';
import DOMPurify from 'dompurify';
import { marked } from 'marked';
import { Copy, ExternalLink, GitFork, Globe, RefreshCw, Scale, Star } from 'lucide-react';
import type { AssetRecord, GitHubRepoMetadata } from '@charkle/shared';
import { getGitHubLanguageColor } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';

export interface GitHubRepoViewerProps {
  asset: AssetRecord;
  repo: GitHubRepoMetadata;
}

export const GitHubRepoViewer: React.FC<GitHubRepoViewerProps> = ({ asset, repo }) => {
  const refreshRichAsset = useLibraryStore((s) => s.refreshRichAsset);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [mode, setMode] = useState<'rendered' | 'raw'>('rendered');
  const [refreshing, setRefreshing] = useState(false);

  const readmeHtml = useMemo(() => {
    if (!repo.readmeMarkdown || mode !== 'rendered') return '';
    const raw = marked.parse(repo.readmeMarkdown, { async: false }) as string;
    return DOMPurify.sanitize(raw);
  }, [repo.readmeMarkdown, mode]);

  const handleRefresh = async () => {
    setRefreshing(true);
    try {
      await refreshRichAsset(asset.id);
      pushToast({ tone: 'success', message: '已刷新 GitHub 仓库元数据与 README' });
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '刷新失败' });
    } finally {
      setRefreshing(false);
    }
  };

  return (
    <div className="w-[min(800px,92vw)] h-[min(700px,78vh)] rounded-[var(--radius-dock-outer)] overflow-hidden bg-[#111317] text-[#E6EDF3] border border-white/12 shadow-2xl flex flex-col">
      {/* Dark Studio Header */}
      <div className="p-5 bg-[#191D24] border-b border-white/10 shrink-0 flex flex-col gap-3">
        <div className="flex items-start justify-between gap-3">
          <div className="flex items-center gap-3 min-w-0">
            {repo.ownerAvatarURL && (
              <img
                src={repo.ownerAvatarURL}
                alt={repo.owner}
                className="h-10 w-10 rounded-full border border-white/15 shrink-0"
              />
            )}
            <div className="min-w-0">
              <h2 className="text-[16px] font-semibold text-white truncate">{repo.fullName}</h2>
              {repo.description && (
                <p className="text-[12.5px] text-[#9CA3AF] line-clamp-2 mt-0.5">
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
              title="刷新仓库元数据"
              className="charkle-pressable h-8 w-8 rounded-[var(--radius-chip)] bg-white/8 hover:bg-white/14 text-white flex items-center justify-center cursor-pointer"
            >
              <RefreshCw size={14} className={refreshing ? 'animate-spin' : ''} />
            </button>
            {repo.homepageURL && (
              <a
                href={repo.homepageURL}
                target="_blank"
                rel="noreferrer"
                className="charkle-pressable h-8 px-2.5 rounded-[var(--radius-chip)] bg-white/8 hover:bg-white/14 text-[12px] text-white inline-flex items-center gap-1.5"
              >
                <Globe size={13} />
                主页
              </a>
            )}
            <a
              href={asset.sourceURL || `https://github.com/${repo.fullName}`}
              target="_blank"
              rel="noreferrer"
              className="charkle-pressable h-8 px-3 rounded-[var(--radius-chip)] bg-[#2A60E0] hover:bg-[#3B70F0] text-[12px] font-medium text-white inline-flex items-center gap-1.5"
            >
              <ExternalLink size={13} />
              在 GitHub 打开
            </a>
          </div>
        </div>

        {/* Stats + Language + License Pills */}
        <div className="flex flex-wrap items-center gap-2 text-[12px]">
          <span className="inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-[#242A35] text-[#F2C14E] font-medium">
            <Star size={12} className="fill-[#F2C14E]" />
            {repo.stars.toLocaleString()}
          </span>
          <span className="inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-[#242A35] text-[#CBD5E1]">
            <GitFork size={12} />
            {repo.forks.toLocaleString()}
          </span>
          {repo.language && (
            <span className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-[#242A35] text-[#E2E8F0]">
              <span
                className="h-2.5 w-2.5 rounded-full"
                style={{ backgroundColor: getGitHubLanguageColor(repo.language) }}
              />
              {repo.language}
            </span>
          )}
          {repo.licenseName && (
            <span className="inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-[#242A35] text-[#9CA3AF]">
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
                className="px-2 py-0.5 rounded-full bg-[#1E3A5F]/60 text-[#93C5FD] text-[11px] font-medium"
              >
                {topic}
              </span>
            ))}
          </div>
        )}
      </div>

      {/* README Toolbar */}
      <div className="px-5 py-2 border-b border-white/8 bg-[#15181E] flex items-center justify-between shrink-0">
        <span className="text-[11.5px] font-mono text-[#9CA3AF]">
          README.md ({repo.defaultBranch})
        </span>
        <div className="flex items-center gap-2">
          <div className="inline-flex p-0.5 rounded-[var(--radius-chip)] bg-white/8">
            {(['rendered', 'raw'] as const).map((m) => (
              <button
                key={m}
                type="button"
                onClick={() => setMode(m)}
                className={[
                  'px-2 py-0.5 text-[11px] rounded-[6px] cursor-pointer',
                  mode === m ? 'bg-white/18 text-white font-medium' : 'text-[#9CA3AF]',
                ].join(' ')}
              >
                {m === 'rendered' ? '排版视图' : '源码'}
              </button>
            ))}
          </div>
          {repo.readmeMarkdown && (
            <button
              type="button"
              onClick={async () => {
                await navigator.clipboard.writeText(repo.readmeMarkdown ?? '').catch(() => {});
                pushToast({ tone: 'info', message: '已复制 README 原文' });
              }}
              className="charkle-pressable h-6.5 px-2 inline-flex items-center gap-1 rounded-[6px] bg-white/8 hover:bg-white/14 text-[11px] text-[#E2E8F0] cursor-pointer"
            >
              <Copy size={11} />
              复制 README
            </button>
          )}
        </div>
      </div>

      {/* README Content */}
      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-6">
        {!repo.readmeMarkdown ? (
          <div className="py-12 text-center text-[13px] text-[#8B949E]">
            暂未获取到 README 文档，可点击右上角刷新重试。
          </div>
        ) : mode === 'rendered' ? (
          <article
            className="text-[13.5px] leading-relaxed text-[#E6EDF3] [&_h1]:text-xl [&_h1]:font-semibold [&_h1]:pb-2 [&_h1]:border-b [&_h1]:border-white/10 [&_h1]:mb-3 [&_h2]:text-lg [&_h2]:font-semibold [&_h2]:mt-5 [&_h2]:mb-2 [&_p]:mb-3 [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:rounded [&_code]:bg-white/10 [&_pre]:p-3.5 [&_pre]:rounded-[10px] [&_pre]:bg-[#1B2028] [&_pre]:overflow-x-auto [&_a]:text-[#60A5FA] [&_img]:max-w-full [&_img]:rounded-[8px] [&_ul]:list-disc [&_ul]:pl-5 [&_ol]:list-decimal [&_ol]:pl-5"
            dangerouslySetInnerHTML={{ __html: readmeHtml }}
          />
        ) : (
          <pre className="text-[12px] font-mono leading-relaxed whitespace-pre-wrap break-words text-[#C9D1D9]">
            {repo.readmeMarkdown}
          </pre>
        )}
      </div>
    </div>
  );
};
