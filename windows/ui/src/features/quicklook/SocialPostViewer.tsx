import React, { useMemo, useState } from 'react';
import { ChevronLeft, ChevronRight, ExternalLink, Heart, MessageCircle, Repeat2 } from 'lucide-react';
import { getTransport } from '../../api/transport';
import { Button } from '../../design-system';
import type { AssetRecord } from '../../types/domain';

export interface SocialPostViewerProps {
  asset: AssetRecord;
}

const PLATFORM_NAME: Record<string, string> = {
  x: 'X',
  threads: 'Threads',
  bluesky: 'Bluesky',
};

export const SocialPostViewer: React.FC<SocialPostViewerProps> = ({ asset }) => {
  const post = asset.richMetadata?.socialPost;
  const [slideIndex, setSlideIndex] = useState(0);

  const slides = useMemo(() => {
    if (!post) return [];
    if (post.attachments.length > 0) return post.attachments;
    return post.mediaURLs.map((url, idx) => ({
      id: `media-${idx}`,
      kind: 'photo' as const,
      url,
      thumbnailURL: post.mediaThumbnailURLs[idx] ?? null,
    }));
  }, [post]);

  if (!post) return null;
  const activeSlide = slides[Math.min(slideIndex, Math.max(0, slides.length - 1))] ?? null;

  return (
    <div
      data-testid="quicklook-social-viewer"
      className="w-full max-w-[720px] max-h-[80vh] mx-auto rounded-[var(--radius-dock-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl flex flex-col overflow-hidden"
    >
      <div className="p-5 border-b border-[var(--border-hairline)] flex items-center justify-between gap-3 shrink-0">
        <div className="flex items-center gap-3 min-w-0">
          {post.authorAvatarURL ? (
            <img
              src={post.authorAvatarURL}
              alt={post.authorName}
              className="h-10 w-10 rounded-full object-cover bg-[var(--bg-subtle)] shrink-0"
            />
          ) : (
            <div className="h-10 w-10 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] flex items-center justify-center font-semibold text-[14px] shrink-0">
              {post.authorName.slice(0, 1).toUpperCase()}
            </div>
          )}
          <div className="min-w-0">
            <div className="text-[14px] font-semibold text-[var(--text-primary)] truncate">
              {post.authorName}
            </div>
            <div className="text-[12px] text-[var(--text-secondary)] truncate">
              {post.authorHandle} · {PLATFORM_NAME[post.platform] ?? post.platform}
              {post.publishedAtText ? ` · ${post.publishedAtText}` : ''}
            </div>
          </div>
        </div>

        <Button
          variant="secondary"
          size="xs"
          onClick={() => void getTransport().openExternalUrl(post.originalURL)}
        >
          <ExternalLink size={12.5} />
          查看原帖
        </Button>
      </div>

      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-5 flex flex-col gap-4">
        {post.articleTitle && (
          <h3 className="text-[17px] font-semibold text-[var(--text-primary)] charkle-heading">
            {post.articleTitle}
          </h3>
        )}

        <p className="text-[14px] leading-[1.68] text-[var(--text-primary)] whitespace-pre-wrap charkle-prose">
          {post.bodyText}
        </p>

        {post.quotedText && (
          <div className="p-3.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)]">
            {post.quotedAuthor && (
              <div className="text-[12px] font-semibold text-[var(--text-primary)] mb-1">
                {post.quotedAuthor}
              </div>
            )}
            <p className="text-[12.5px] text-[var(--text-secondary)] leading-relaxed whitespace-pre-wrap">
              {post.quotedText}
            </p>
          </div>
        )}

        {activeSlide && (
          <div className="relative rounded-[var(--radius-card-outer)] overflow-hidden bg-black/90 flex items-center justify-center min-h-[260px] max-h-[420px]">
            {activeSlide.kind === 'video' ? (
              <video
                key={activeSlide.url}
                src={activeSlide.url}
                poster={activeSlide.thumbnailURL ?? undefined}
                controls
                playsInline
                className="max-w-full max-h-[420px]"
              />
            ) : (
              <img
                src={activeSlide.url}
                alt=""
                className="max-w-full max-h-[420px] object-contain"
              />
            )}

            {slides.length > 1 && (
              <>
                <button
                  type="button"
                  aria-label="上一张附件"
                  onClick={() =>
                    setSlideIndex((i) => (i - 1 + slides.length) % slides.length)
                  }
                  className="charkle-glass-dark absolute left-2.5 top-1/2 -translate-y-1/2 h-8 w-8 rounded-full inline-flex items-center justify-center cursor-pointer"
                >
                  <ChevronLeft size={16} />
                </button>
                <button
                  type="button"
                  aria-label="下一张附件"
                  onClick={() => setSlideIndex((i) => (i + 1) % slides.length)}
                  className="charkle-glass-dark absolute right-2.5 top-1/2 -translate-y-1/2 h-8 w-8 rounded-full inline-flex items-center justify-center cursor-pointer"
                >
                  <ChevronRight size={16} />
                </button>
                <div className="charkle-glass-dark absolute bottom-2.5 right-3 px-2 py-0.5 rounded-full text-[11px] charkle-tabular">
                  {slideIndex + 1} / {slides.length}
                </div>
              </>
            )}
          </div>
        )}

        {(post.likeCount != null || post.repostCount != null || post.replyCount != null) && (
          <div className="flex items-center gap-5 pt-2 border-t border-[var(--border-hairline)] text-[12px] text-[var(--text-tertiary)] charkle-tabular">
            {post.replyCount != null && (
              <span className="inline-flex items-center gap-1">
                <MessageCircle size={13} />
                {post.replyCount.toLocaleString()}
              </span>
            )}
            {post.repostCount != null && (
              <span className="inline-flex items-center gap-1">
                <Repeat2 size={13} />
                {post.repostCount.toLocaleString()}
              </span>
            )}
            {post.likeCount != null && (
              <span className="inline-flex items-center gap-1">
                <Heart size={13} />
                {post.likeCount.toLocaleString()}
              </span>
            )}
          </div>
        )}
      </div>
    </div>
  );
};
