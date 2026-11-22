import React, { useMemo, useState } from 'react';
import {
  AlertTriangle,
  ChevronLeft,
  ChevronRight,
  Download,
  ExternalLink,
  Eye,
  Heart,
  MessageCircle,
  RefreshCw,
  Repeat2,
} from 'lucide-react';
import {
  getEffectiveSocialAttachments,
  socialPlatformDisplayName,
  socialPlatformOpenActionLabel,
} from '@charkle/shared';
import type { AssetRecord, SocialPlatform, SocialPostMetadata } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { Button } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';

const PLATFORM_PILL_BG: Record<SocialPlatform, string> = {
  x: '#18181B',
  threads: '#27272A',
  bluesky: '#0284C7',
};

export interface SocialPostViewerProps {
  asset: AssetRecord;
  post: SocialPostMetadata;
}

export const SocialPostViewer: React.FC<SocialPostViewerProps> = ({ asset, post }) => {
  const refreshRichAsset = useLibraryStore((s) => s.refreshRichAsset);
  const extractSocialMedia = useLibraryStore((s) => s.extractSocialMedia);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const attachments = useMemo(() => getEffectiveSocialAttachments(post), [post]);
  const [slideIndex, setSlideIndex] = useState(0);
  const [refreshing, setRefreshing] = useState(false);
  const [extracting, setExtracting] = useState(false);

  const safeIndex = Math.min(slideIndex, Math.max(0, attachments.length - 1));
  const currentAtt = attachments[safeIndex] ?? null;

  const handleRefresh = async () => {
    setRefreshing(true);
    try {
      await refreshRichAsset(asset.id);
      pushToast({ tone: 'success', message: '已重新抓取推文与媒体附件' });
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '重新抓取失败' });
    } finally {
      setRefreshing(false);
    }
  };

  const handleExtract = async (idx: number | null) => {
    setExtracting(true);
    try {
      await extractSocialMedia(asset.id, idx);
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '提取媒体失败' });
    } finally {
      setExtracting(false);
    }
  };

  return (
    <div className="w-[min(740px,92vw)] max-h-[82vh] rounded-[var(--radius-dock-outer)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl flex flex-col">
      {/* Header */}
      <div className="px-5 py-4 border-b border-[var(--border-hairline)] flex items-center justify-between gap-3 shrink-0">
        <div className="flex items-center gap-3 min-w-0">
          {post.authorAvatarURL ? (
            <img
              src={post.authorAvatarURL}
              alt={post.authorName}
              className="h-10 w-10 rounded-full object-cover border border-[var(--border-hairline)] shrink-0"
            />
          ) : (
            <span className="h-10 w-10 rounded-full bg-[var(--bg-subtle)] text-[var(--text-primary)] font-semibold flex items-center justify-center shrink-0">
              {post.authorName.slice(0, 1).toUpperCase()}
            </span>
          )}
          <div className="min-w-0">
            <div className="flex items-center gap-2">
              <span className="text-[14px] font-semibold text-[var(--text-primary)] truncate">
                {post.authorName}
              </span>
              <span
                className="px-2 py-0.5 rounded-full text-[10.5px] font-semibold text-white shrink-0"
                style={{ backgroundColor: PLATFORM_PILL_BG[post.platform] }}
              >
                {socialPlatformDisplayName(post.platform)}
              </span>
            </div>
            <div className="text-[12px] text-[var(--text-secondary)] truncate">
              @{post.authorHandle}
              {post.publishedAtText && ` · ${post.publishedAtText}`}
            </div>
          </div>
        </div>

        <div className="flex items-center gap-1.5 shrink-0">
          <Button
            variant="ghost"
            size="xs"
            loading={refreshing}
            onClick={() => void handleRefresh()}
            title="刷新推文与媒体"
          >
            <RefreshCw size={13} />
          </Button>
          <a
            href={post.originalURL}
            target="_blank"
            rel="noreferrer"
            className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] hover:bg-[var(--border-hairline)] text-[12px] font-medium text-[var(--text-primary)]"
          >
            <ExternalLink size={12} />
            {socialPlatformOpenActionLabel(post.platform)}
          </a>
        </div>
      </div>

      {/* Scrollable Body + Media Carousel */}
      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-5 flex flex-col gap-4">
        {post.mediaFetchFailed && (
          <div className="px-3.5 py-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--warning-soft)] text-[var(--warning)] text-[12.5px] flex items-center justify-between gap-2">
            <span className="inline-flex items-center gap-2">
              <AlertTriangle size={15} />
              原推文部分媒体资源抓取失败，建议点击重试获取。
            </span>
            <Button variant="secondary" size="xs" loading={refreshing} onClick={() => void handleRefresh()}>
              重试获取
            </Button>
          </div>
        )}

        {post.articleTitle && (
          <h3 className="text-[16px] font-semibold text-[var(--text-primary)] leading-snug">
            {post.articleTitle}
          </h3>
        )}

        {post.bodyText && (
          <p className="text-[14px] leading-relaxed whitespace-pre-wrap text-[var(--text-primary)]">
            {post.bodyText}
          </p>
        )}

        {/* Quoted Post Card */}
        {(post.quotedAuthor || post.quotedText) && (
          <div className="p-3.5 rounded-[var(--radius-settings-outer)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] flex flex-col gap-1">
            {post.quotedAuthor && (
              <div className="text-[12px] font-semibold text-[var(--text-secondary)]">
                引用自 {post.quotedAuthor}
              </div>
            )}
            {post.quotedText && (
              <p className="text-[13px] leading-relaxed text-[var(--text-primary)] whitespace-pre-wrap">
                {post.quotedText}
              </p>
            )}
          </div>
        )}

        {/* Multi-Attachment Carousel */}
        {currentAtt && (
          <div className="relative rounded-[var(--radius-settings-outer)] overflow-hidden bg-black/90 flex items-center justify-center min-h-[260px] max-h-[420px]">
            {currentAtt.kind === 'video' || currentAtt.kind === 'gif' ? (
              <video
                key={currentAtt.id}
                src={
                  post.hasVideo && safeIndex === 0
                    ? apiClient.originalMediaURL(asset.id)
                    : currentAtt.url
                }
                poster={currentAtt.thumbnailURL ?? undefined}
                controls
                loop={currentAtt.kind === 'gif'}
                playsInline
                className="max-w-full max-h-[420px] object-contain"
              />
            ) : (
              <img
                key={currentAtt.id}
                src={currentAtt.url}
                alt={`推文附件 ${safeIndex + 1}`}
                className="max-w-full max-h-[420px] object-contain"
              />
            )}

            {attachments.length > 1 && (
              <>
                <button
                  type="button"
                  disabled={safeIndex <= 0}
                  onClick={() => setSlideIndex((i) => Math.max(0, i - 1))}
                  className="charkle-pressable absolute left-2.5 top-1/2 -translate-y-1/2 h-8 w-8 rounded-full bg-black/60 text-white flex items-center justify-center disabled:opacity-25 cursor-pointer"
                >
                  <ChevronLeft size={16} />
                </button>
                <button
                  type="button"
                  disabled={safeIndex >= attachments.length - 1}
                  onClick={() => setSlideIndex((i) => Math.min(attachments.length - 1, i + 1))}
                  className="charkle-pressable absolute right-2.5 top-1/2 -translate-y-1/2 h-8 w-8 rounded-full bg-black/60 text-white flex items-center justify-center disabled:opacity-25 cursor-pointer"
                >
                  <ChevronRight size={16} />
                </button>
                <div className="absolute bottom-2.5 left-1/2 -translate-x-1/2 flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-black/55">
                  {attachments.map((att, idx) => (
                    <button
                      key={att.id}
                      type="button"
                      onClick={() => setSlideIndex(idx)}
                      className={[
                        'h-1.5 rounded-full transition-[width,background-color] duration-[180ms] ease-[var(--ease-out)] cursor-pointer',
                        idx === safeIndex ? 'w-4 bg-white' : 'w-1.5 bg-white/45',
                      ].join(' ')}
                    />
                  ))}
                </div>
              </>
            )}
          </div>
        )}

        {/* Stats + Media Extraction Actions */}
        <div className="flex flex-wrap items-center justify-between gap-3 pt-2 border-t border-[var(--border-hairline)]">
          <div className="flex items-center gap-4 text-[12px] text-[var(--text-secondary)]">
            {typeof post.replyCount === 'number' && (
              <span className="inline-flex items-center gap-1">
                <MessageCircle size={13} />
                {post.replyCount.toLocaleString()}
              </span>
            )}
            {typeof post.repostCount === 'number' && (
              <span className="inline-flex items-center gap-1">
                <Repeat2 size={14} />
                {post.repostCount.toLocaleString()}
              </span>
            )}
            {typeof post.likeCount === 'number' && (
              <span className="inline-flex items-center gap-1">
                <Heart size={13} />
                {post.likeCount.toLocaleString()}
              </span>
            )}
            {typeof post.viewCount === 'number' && (
              <span className="inline-flex items-center gap-1">
                <Eye size={13} />
                {post.viewCount.toLocaleString()}
              </span>
            )}
          </div>

          {attachments.length > 0 && (
            <div className="flex items-center gap-2">
              <Button
                variant="secondary"
                size="xs"
                loading={extracting}
                onClick={() => void handleExtract(safeIndex)}
              >
                <Download size={12} />
                提取当前媒体
              </Button>
              {attachments.length > 1 && (
                <Button
                  variant="primary"
                  size="xs"
                  loading={extracting}
                  onClick={() => void handleExtract(null)}
                >
                  全部提取为独立素材 ({attachments.length})
                </Button>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
};
