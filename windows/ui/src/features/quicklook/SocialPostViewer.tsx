import React, { useEffect, useMemo, useRef, useState } from 'react';
import { ExternalLink, Film, ImageOff, ImagePlus, Images, RefreshCw } from 'lucide-react';
import { getTransport, isTauriRuntime } from '../../api/transport';
import {
  getEffectiveSocialAttachments,
  useCoordinatorStore,
  useLibraryStore,
} from '../../stores';
import {
  formatSocialDisplayHandle,
  resolveSocialMediaUrl,
  type AssetRecord,
  type SocialMediaAttachment,
} from '../../types/domain';

export interface SocialPostViewerProps {
  asset: AssetRecord;
}

const SocialAttachmentVideo: React.FC<{
  src?: string;
  poster?: string;
  onError: () => void;
}> = ({ src, poster, onError }) => {
  const videoRef = useRef<HTMLVideoElement | null>(null);
  useEffect(() => {
    const el = videoRef.current;
    return () => {
      if (el) {
        el.pause();
        el.removeAttribute('src');
        try {
          el.load();
        } catch {
          // Ignore in jsdom
        }
      }
    };
  }, [src]);

  return (
    <video
      ref={videoRef}
      src={src}
      poster={poster}
      controls
      playsInline
      onError={onError}
      className="w-full max-h-[340px] rounded-[12px] bg-black border border-[var(--border-hairline)]"
    />
  );
};

const PLATFORM_META: Record<
  string,
  { name: string; openLabel: string; badgeBg: string; noun: string }
> = {
  x: { name: 'X', openLabel: '在 X 中打开', badgeBg: '#18181B', noun: '推文' },
  threads: { name: 'Threads', openLabel: '在 Threads 中打开', badgeBg: '#27272A', noun: '推文' },
  bluesky: { name: 'Bluesky', openLabel: '在 Bluesky 中打开', badgeBg: '#0284C7', noun: '推文' },
  xiaohongshu: { name: '小红书', openLabel: '在小红书中打开', badgeBg: '#FF2442', noun: '笔记' },
};

export const SocialPostViewer: React.FC<SocialPostViewerProps> = ({ asset }) => {
  const post = asset.richMetadata?.socialPost;
  const destination = useCoordinatorStore((s) => s.destination);
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const extractSocialAttachment = useLibraryStore((s) => s.extractSocialAttachment);
  const extractAllSocialAttachments = useLibraryStore((s) => s.extractAllSocialAttachments);
  const refreshRichAsset = useLibraryStore((s) => s.refreshRichAsset);

  const [extractingKey, setExtractingKey] = useState<string | null>(null);
  const [retrying, setRetrying] = useState(false);
  const [avatarFailed, setAvatarFailed] = useState(false);
  const [failedMediaKeys, setFailedMediaKeys] = useState<Record<string, boolean>>({});

  useEffect(() => {
    setAvatarFailed(false);
    setFailedMediaKeys({});
    setRetrying(false);
    setExtractingKey(null);
  }, [asset.id]);

  const attachments = useMemo(() => getEffectiveSocialAttachments(post), [post]);

  if (!post) return null;

  const inTauri = isTauriRuntime();
  const platform = PLATFORM_META[post.platform] ?? {
    name: post.platform,
    openLabel: '查看原帖',
    badgeBg: '#18181B',
    noun: '推文',
  };
  const isXiaohongshu = post.platform === 'xiaohongshu';
  const displayHandle = formatSocialDisplayHandle(post);
  const avatarSrc = resolveSocialMediaUrl(post.authorAvatarURL, inTauri);
  const useSingleColumn =
    attachments.length === 1 ||
    attachments.some((a) => a.kind === 'video' || a.kind === 'gif');
  const isXiaohongshuMultiGrid = isXiaohongshu && !useSingleColumn && attachments.length > 1;

  const openOriginalPost = () => {
    void getTransport()
      .openExternalUrl(post.originalURL)
      .catch(() => {
        pushToast({ message: '无法在默认浏览器中打开原帖链接', tone: 'error' });
      });
  };

  const handleExtractOne = async (att: SocialMediaAttachment, idx: number) => {
    const key = `${att.id}-${idx}`;
    setExtractingKey(key);
    try {
      const created = await extractSocialAttachment(asset, att, idx, destination);
      if (created) {
        pushToast({
          message: `已提取「${created.title}」并保留${platform.noun}来源`,
          tone: 'success',
        });
      }
    } catch (err) {
      pushToast({
        message: `提取${platform.noun}媒体失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setExtractingKey(null);
    }
  };

  const handleExtractAll = async () => {
    setExtractingKey('__all__');
    try {
      const created = await extractAllSocialAttachments(asset, destination);
      if (created.length > 0) {
        pushToast({
          message: `已提取 ${created.length} 项${platform.noun}媒体为独立素材`,
          tone: 'success',
        });
      }
    } catch (err) {
      pushToast({
        message: `批量提取失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setExtractingKey(null);
    }
  };

  return (
    <div
      data-testid="quicklook-social-viewer"
      onClick={(e) => e.stopPropagation()}
      className="w-full max-w-[680px] max-h-[82vh] mx-auto rounded-[18px] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-[0_24px_60px_rgba(0,0,0,0.42)] flex flex-col overflow-hidden"
    >
      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-6 flex flex-col gap-4">
        {/* Author Header (1:1 macOS QuickLookSocialPostCard) */}
        <div className="flex items-center gap-3">
          {avatarSrc && !avatarFailed ? (
            <img
              src={avatarSrc}
              alt={post.authorName}
              onError={() => setAvatarFailed(true)}
              className="h-10 w-10 rounded-full object-cover bg-[var(--bg-subtle)] shrink-0"
            />
          ) : (
            <div
              style={{ backgroundColor: platform.badgeBg }}
              className="h-10 w-10 rounded-full text-white flex items-center justify-center font-bold text-[15px] shrink-0"
            >
              {(post.authorName || post.authorHandle.replace(/^@+/, '') || 'X')
                .slice(0, 1)
                .toUpperCase()}
            </div>
          )}

          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-1.5 min-w-0">
              <span className="text-[14.5px] font-bold text-[var(--text-primary)] truncate">
                {post.authorName}
              </span>
              {displayHandle && (
                <span className="text-[12.5px] text-[var(--text-secondary)] truncate">
                  {displayHandle}
                </span>
              )}
            </div>
            {post.publishedAtText && (
              <div className="text-[11.5px] text-[var(--text-tertiary)] truncate">
                {post.publishedAtText}
              </div>
            )}
          </div>

          <span
            style={{ backgroundColor: platform.badgeBg }}
            className="px-2.5 py-1 rounded-full text-[11px] font-bold text-white shrink-0"
          >
            {platform.name}
          </span>
        </div>

        {/* Article / Note Headline */}
        {post.articleTitle && (
          <h3 className="text-[17px] font-bold text-[var(--text-primary)] select-text charkle-heading">
            {post.articleTitle}
          </h3>
        )}

        {/* Body Text */}
        {post.bodyText.trim() && (
          <p className="text-[15px] leading-[1.68] text-[var(--text-primary)] whitespace-pre-wrap select-text charkle-prose">
            {post.bodyText}
          </p>
        )}

        {/* Quoted Post */}
        {post.quotedText && (
          <div className="p-3 rounded-[12px] bg-[var(--bg-subtle)]/70 border border-[var(--border-hairline)] flex flex-col gap-1.5">
            {post.quotedAuthor && (
              <div className="text-[12px] font-semibold text-[var(--text-secondary)]">
                {post.quotedAuthor}
              </div>
            )}
            <p className="text-[13.5px] text-[var(--text-primary)]/85 leading-relaxed whitespace-pre-wrap select-text">
              {post.quotedText}
            </p>
          </div>
        )}

        {/* Embedded Attachments with Independent Extraction */}
        {attachments.length > 0 && (
          <div className="flex flex-col gap-2.5">
            {attachments.length > 1 && (
              <div className="flex items-center justify-between gap-2">
                <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
                  {platform.noun}内含 {attachments.length} 个媒体
                </span>
                <button
                  type="button"
                  disabled={extractingKey !== null}
                  onClick={() => void handleExtractAll()}
                  className="charkle-pressable inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-[var(--accent-soft)] hover:bg-[var(--accent)]/20 text-[11px] font-semibold text-[var(--accent)] disabled:opacity-50 cursor-pointer"
                >
                  <Images size={11.5} />
                  <span>
                    {extractingKey === '__all__' ? '正在提取…' : '全部提取为独立素材'}
                  </span>
                </button>
              </div>
            )}

            <div
              className={
                useSingleColumn ? 'grid grid-cols-1 gap-2.5' : 'grid grid-cols-2 gap-2'
              }
            >
              {attachments.map((att, idx) => {
                const isVideoLike = att.kind === 'video' || att.kind === 'gif';
                const extractLabel =
                  att.kind === 'video'
                    ? '提取为单独视频'
                    : att.kind === 'gif'
                      ? '提取为单独动图'
                      : '提取为单独图片';
                const key = `${att.id}-${idx}`;
                const resolvedMediaUrl = resolveSocialMediaUrl(att.url, inTauri);
                const resolvedThumbUrl = resolveSocialMediaUrl(att.thumbnailURL, inTauri);
                const mediaFailed = Boolean(failedMediaKeys[key]);

                if (isVideoLike) {
                  return (
                    <div key={key} className="flex flex-col gap-1.5">
                      {mediaFailed ? (
                        <div className="w-full h-[200px] rounded-[12px] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] flex flex-col items-center justify-center gap-2 text-[12px] text-[var(--text-secondary)]">
                          <Film size={22} className="text-[var(--text-tertiary)]" />
                          <span>视频暂时无法在线加载</span>
                          <button
                            type="button"
                            onClick={openOriginalPost}
                            className="text-[var(--accent)] font-medium hover:underline cursor-pointer"
                          >
                            {platform.openLabel}
                          </button>
                        </div>
                      ) : (
                        <SocialAttachmentVideo
                          src={resolvedMediaUrl}
                          poster={resolvedThumbUrl}
                          onError={() =>
                            setFailedMediaKeys((prev) => ({ ...prev, [key]: true }))
                          }
                        />
                      )}
                      <div className="flex items-center justify-between">
                        <span className="inline-flex items-center gap-1 text-[11px] font-medium text-[var(--text-secondary)]">
                          <Film size={12} />
                          {att.kind === 'gif' ? '动图媒体' : '视频媒体'}
                        </span>
                        <button
                          type="button"
                          disabled={extractingKey !== null}
                          onClick={() => void handleExtractOne(att, idx)}
                          className="charkle-pressable inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-[var(--accent-soft)] hover:bg-[var(--accent)]/20 text-[11px] font-semibold text-[var(--accent)] disabled:opacity-50 cursor-pointer"
                        >
                          <Film size={11} />
                          <span>{extractingKey === key ? '提取中…' : extractLabel}</span>
                        </button>
                      </div>
                    </div>
                  );
                }

                // Prefer high-res original photo URL (falling back to thumbnailURL)
                const photoSrc = resolvedMediaUrl || resolvedThumbUrl;

                return (
                  <div
                    key={key}
                    className={[
                      'relative rounded-[12px] overflow-hidden bg-[var(--bg-subtle)]/70 border border-[var(--border-hairline)]',
                      isXiaohongshuMultiGrid ? 'aspect-[3/4]' : '',
                    ].join(' ')}
                  >
                    {mediaFailed || !photoSrc ? (
                      <div className="w-full min-h-[180px] h-full flex flex-col items-center justify-center gap-1.5 p-4 text-center text-[11.5px] text-[var(--text-secondary)]">
                        <ImageOff size={20} className="text-[var(--text-tertiary)]" />
                        <span>原图链接已失效或受防盗链限制</span>
                      </div>
                    ) : (
                      <img
                        src={photoSrc}
                        alt=""
                        onError={() =>
                          setFailedMediaKeys((prev) => ({ ...prev, [key]: true }))
                        }
                        className={
                          isXiaohongshuMultiGrid
                            ? 'w-full h-full object-cover'
                            : [
                                'w-full object-contain',
                                attachments.length === 1
                                  ? isXiaohongshu
                                    ? 'max-h-[520px]'
                                    : 'max-h-[420px]'
                                  : 'max-h-[240px]',
                              ].join(' ')
                        }
                      />
                    )}
                    <button
                      type="button"
                      disabled={extractingKey !== null}
                      title={`将此媒体提取为独立素材，并自动在备注和来源链接中保留原${platform.noun}出处`}
                      onClick={() => void handleExtractOne(att, idx)}
                      className="charkle-pressable absolute bottom-2.5 right-2.5 inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-black/75 hover:bg-black/88 text-white text-[11px] font-semibold disabled:opacity-50 cursor-pointer"
                    >
                      <ImagePlus size={11.5} />
                      <span>{extractingKey === key ? '提取中…' : extractLabel}</span>
                    </button>
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {/* Media Fetch Failed Banner + Retry CTA */}
        {post.mediaFetchFailed && (
          <div className="flex flex-col items-start gap-2 p-3 rounded-[10px] bg-[var(--bg-subtle)]">
            <div className="text-[12px] text-[var(--text-secondary)]">
              媒体暂未保存到本地 ·{' '}
              <button
                type="button"
                onClick={openOriginalPost}
                className="font-medium text-[var(--accent)] hover:underline cursor-pointer"
              >
                前往 {platform.name} 观看
              </button>
            </div>
            <button
              type="button"
              disabled={retrying}
              onClick={async () => {
                setRetrying(true);
                try {
                  await refreshRichAsset(asset.id);
                  setFailedMediaKeys({});
                } catch (err) {
                  pushToast({
                    message: `重新获取失败：${err instanceof Error ? err.message : String(err)}`,
                    tone: 'error',
                  });
                } finally {
                  setRetrying(false);
                }
              }}
              className="charkle-pressable inline-flex items-center gap-1.5 px-3.5 py-1.5 rounded-full bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-white text-[12px] font-semibold disabled:opacity-50 cursor-pointer"
            >
              <RefreshCw size={11.5} className={retrying ? 'animate-spin' : ''} />
              <span>重试获取</span>
            </button>
          </div>
        )}

        <div className="h-px bg-[var(--border-hairline)]" />

        {/* Engagement Counts + Open Original */}
        <div className="flex items-center gap-4 flex-wrap text-[12.5px] charkle-tabular">
          {post.replyCount != null && (
            <span className="inline-flex items-baseline gap-1">
              <strong className="font-bold text-[var(--text-primary)]">
                {post.replyCount.toLocaleString()}
              </strong>
              <span className="text-[var(--text-secondary)]">replies</span>
            </span>
          )}
          {post.repostCount != null && (
            <span className="inline-flex items-baseline gap-1">
              <strong className="font-bold text-[var(--text-primary)]">
                {post.repostCount.toLocaleString()}
              </strong>
              <span className="text-[var(--text-secondary)]">reposts</span>
            </span>
          )}
          {post.likeCount != null && (
            <span className="inline-flex items-baseline gap-1">
              <strong className="font-bold text-[var(--text-primary)]">
                {post.likeCount.toLocaleString()}
              </strong>
              <span className="text-[var(--text-secondary)]">likes</span>
            </span>
          )}
          {post.viewCount != null && (
            <span className="inline-flex items-baseline gap-1">
              <strong className="font-bold text-[var(--text-primary)]">
                {post.viewCount.toLocaleString()}
              </strong>
              <span className="text-[var(--text-secondary)]">views</span>
            </span>
          )}

          <span className="flex-1" />

          <button
            type="button"
            onClick={openOriginalPost}
            className="inline-flex items-center gap-1 text-[12.5px] font-semibold text-[var(--accent)] hover:underline cursor-pointer"
          >
            <span>{platform.openLabel}</span>
            <ExternalLink size={12} />
          </button>
        </div>
      </div>
    </div>
  );
};
