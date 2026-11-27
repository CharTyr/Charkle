import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowSync16Regular,
  Camera16Regular,
  ImageAdd20Regular,
  ImageMultiple16Regular,
  ImageOff20Regular,
  Open16Regular,
  VideoClip16Regular,
  VideoClip24Regular,
} from '@fluentui/react-icons';
import { getTransport, isTauriRuntime } from '../../api/transport';
import {
  getEffectiveSocialAttachments,
  useCoordinatorStore,
  useLibraryStore,
} from '../../stores';
import {
  formatSocialDisplayHandle,
  formatVideoDurationText,
  isVideoSocialPlatform,
  resolveSocialMediaUrl,
  type AssetRecord,
  type SocialMediaAttachment,
} from '../../types/domain';
import {
  QuickLookStreamingVideoView,
  captureVideoElementFrameJpeg,
  type CapturedVideoFrame,
} from './QuickLookStreamingVideoView';

export interface SocialPostViewerProps {
  asset: AssetRecord;
}

const SocialAttachmentVideo: React.FC<{
  src?: string;
  poster?: string;
  onError: () => void;
  videoElRef?: React.MutableRefObject<HTMLVideoElement | null>;
}> = ({ src, poster, onError, videoElRef }) => {
  const localRef = useRef<HTMLVideoElement | null>(null);
  useEffect(() => {
    const el = localRef.current;
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
      ref={(node) => {
        localRef.current = node;
        if (videoElRef) videoElRef.current = node;
      }}
      src={src}
      poster={poster}
      crossOrigin="anonymous"
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
  threads: { name: 'Threads', openLabel: '在 Threads 中打开', badgeBg: '#27272A', noun: '贴文' },
  bluesky: { name: 'Bluesky', openLabel: '在 Bluesky 中打开', badgeBg: '#0284C7', noun: '贴文' },
  xiaohongshu: { name: '小红书', openLabel: '在小红书中打开', badgeBg: '#FF2442', noun: '笔记' },
  pixiv: { name: 'Pixiv', openLabel: '在 Pixiv 打开', badgeBg: '#0096FA', noun: '作品' },
  instagram: { name: 'Instagram', openLabel: '在 Instagram 打开', badgeBg: '#D93B58', noun: '贴文' },
  youtube: { name: 'YouTube', openLabel: '在 YouTube 打开', badgeBg: '#FF0033', noun: '视频' },
  bilibili: { name: 'Bilibili', openLabel: '在 B 站打开', badgeBg: '#FB7299', noun: '视频' },
};

export const SocialPostViewer: React.FC<SocialPostViewerProps> = ({ asset }) => {
  const post = asset.richMetadata?.socialPost;
  const destination = useCoordinatorStore((s) => s.destination);
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const extractSocialAttachment = useLibraryStore((s) => s.extractSocialAttachment);
  const extractAllSocialAttachments = useLibraryStore((s) => s.extractAllSocialAttachments);
  const refreshRichAsset = useLibraryStore((s) => s.refreshRichAsset);
  const updateAssetCoverImage = useLibraryStore((s) => s.updateAssetCoverImage);

  const [extractingKey, setExtractingKey] = useState<string | null>(null);
  const [retrying, setRetrying] = useState(false);
  const [capturingInlineCover, setCapturingInlineCover] = useState(false);
  const [avatarFailed, setAvatarFailed] = useState(false);
  const [failedMediaKeys, setFailedMediaKeys] = useState<Record<string, boolean>>({});
  const [fallbackThumbKeys, setFallbackThumbKeys] = useState<Record<string, boolean>>({});
  const [localVideoFailedKeys, setLocalVideoFailedKeys] = useState<Record<string, boolean>>({});
  const primaryVideoRef = useRef<HTMLVideoElement | null>(null);

  useEffect(() => {
    setAvatarFailed(false);
    setFailedMediaKeys({});
    setFallbackThumbKeys({});
    setLocalVideoFailedKeys({});
    setRetrying(false);
    setExtractingKey(null);
    setCapturingInlineCover(false);
    primaryVideoRef.current = null;
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
  const isVideoPlatform = isVideoSocialPlatform(post.platform);
  const displayHandle = formatSocialDisplayHandle(post);
  const videoDurationText = formatVideoDurationText(
    post.videoDurationSeconds ?? asset.durationSeconds,
  );
  const videoSummaryText = post.videoSummary?.trim() || '';
  const videoOutlineItems = Array.isArray(post.videoOutline)
    ? post.videoOutline.filter((line) => line.trim().length > 0)
    : [];
  const videoCoverSrc =
    resolveSocialMediaUrl(
      attachments[0]?.thumbnailURL ||
        post.mediaThumbnailURLs?.[0] ||
        post.mediaURLs?.[0],
      inTauri,
    ) || getTransport().thumbnailUrl(asset.id, 'preview1400');
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

  const handleRefreshPost = async () => {
    setRetrying(true);
    try {
      await refreshRichAsset(asset.id);
      setAvatarFailed(false);
      setFailedMediaKeys({});
      setFallbackThumbKeys({});
      setLocalVideoFailedKeys({});
    } catch (err) {
      pushToast({
        message: `重新获取失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setRetrying(false);
    }
  };

  const handleApplyCapturedCover = async (frame: CapturedVideoFrame) => {
    await updateAssetCoverImage(asset.id, frame.imageBase64, frame.timestampSeconds);
  };

  const handleCapturePrimaryInlineVideoCover = async () => {
    if (capturingInlineCover) return;
    setCapturingInlineCover(true);
    try {
      const captured = captureVideoElementFrameJpeg(primaryVideoRef.current);
      if (captured) {
        await updateAssetCoverImage(asset.id, captured.imageBase64, captured.timestampSeconds);
      } else {
        pushToast({ message: '视频尚未就绪，请稍后再截取封面', tone: 'info' });
      }
    } finally {
      setCapturingInlineCover(false);
    }
  };

  return (
    <div
      data-testid="quicklook-social-viewer"
      onClick={(e) => e.stopPropagation()}
      className={[
        'w-full max-h-[82vh] mx-auto rounded-[var(--win-radius-dialog)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-flyout)] shadow-[0_24px_60px_rgba(0,0,0,0.42)] flex flex-col overflow-hidden',
        isVideoPlatform ? 'max-w-[760px]' : 'max-w-[680px]',
      ].join(' ')}
    >
      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-6 flex flex-col gap-4">
        {/* Author Header (1:1 macOS QuickLookSocialPostCard) */}
        <div className="flex items-center gap-3">
          {avatarSrc && !avatarFailed ? (
            <img
              src={avatarSrc}
              alt={post.authorName}
              referrerPolicy="no-referrer"
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

        {/* Article / Note / Video Headline */}
        {post.articleTitle && (
          <h3 className="text-[17px] font-bold text-[var(--text-primary)] select-text charkle-heading">
            {post.articleTitle}
          </h3>
        )}

        {/* YouTube / Bilibili Zero-Download Inline Streaming Player & Explicit On-Demand Save */}
        {isVideoPlatform && (
          <div
            data-testid="video-bookmark-stage"
            className="flex flex-col gap-3"
          >
            <QuickLookStreamingVideoView
              assetId={asset.id}
              playbackKey={`${asset.id}:${post.originalURL}`}
              coverSrc={videoCoverSrc}
              coverAlt={post.articleTitle ?? asset.title}
              durationText={videoDurationText}
              watchUrl={post.originalURL}
              openActionLabel={platform.openLabel}
              onOpenExternal={openOriginalPost}
              onSetCoverFrame={handleApplyCapturedCover}
            />

            <div className="flex items-center justify-between gap-2 flex-wrap">
              <span className="text-[11.5px] text-[var(--text-secondary)]">
                在线流式播放（不占用本地空间，可按需保存原视频）
              </span>
              <div className="flex items-center gap-2">
                <button
                  type="button"
                  data-testid="video-bookmark-save-asset"
                  disabled={extractingKey !== null}
                  onClick={() =>
                    void handleExtractOne(
                      {
                        id: 'video-bookmark-0',
                        kind: 'video',
                        url: post.originalURL,
                        thumbnailURL:
                          post.mediaThumbnailURLs?.[0] ?? post.mediaURLs?.[0] ?? null,
                      },
                      0,
                    )
                  }
                  className="charkle-pressable inline-flex items-center gap-1.5 px-3 py-1.5 rounded-[var(--win-radius-control)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-[var(--accent-text)] text-[12px] font-semibold disabled:opacity-50 cursor-pointer"
                >
                  <VideoClip16Regular className="w-3.5 h-3.5" />
                  <span>
                    {extractingKey === 'video-bookmark-0-0'
                      ? '正在保存视频…'
                      : '保存视频为独立素材'}
                  </span>
                </button>
                <button
                  type="button"
                  onClick={openOriginalPost}
                  className="charkle-pressable inline-flex items-center gap-1 px-2.5 py-1.5 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)] hover:bg-[var(--win-subtle-hover)] text-[var(--text-primary)] text-[12px] font-medium cursor-pointer"
                >
                  <Open16Regular className="w-3.5 h-3.5" />
                  <span>{platform.openLabel}</span>
                </button>
              </div>
            </div>

            {(videoSummaryText || videoOutlineItems.length > 0) && (
              <div
                data-testid="video-bookmark-summary-card"
                className="p-3.5 rounded-[var(--win-radius-card)] bg-[var(--bg-subtle)]/75 border border-[var(--win-stroke-card)] flex flex-col gap-2"
              >
                <div className="text-[12px] font-bold text-[var(--text-primary)]">
                  视频摘要
                </div>
                {videoSummaryText && (
                  <p className="text-[13px] leading-[1.6] text-[var(--text-primary)]/90 whitespace-pre-wrap select-text">
                    {videoSummaryText}
                  </p>
                )}
                {videoOutlineItems.length > 0 && (
                  <div className="flex flex-col gap-1 pt-1 border-t border-[var(--win-stroke-divider)]">
                    <div className="text-[11px] font-semibold text-[var(--text-secondary)]">
                      章节大纲
                    </div>
                    <ul className="flex flex-col gap-1 text-[12.5px] text-[var(--text-primary)]/85 select-text">
                      {videoOutlineItems.map((line, i) => (
                        <li key={i} className="leading-snug">
                          {line}
                        </li>
                      ))}
                    </ul>
                  </div>
                )}
              </div>
            )}
          </div>
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

        {/* Embedded Attachments with Independent Extraction (non-video-platform social posts) */}
        {!isVideoPlatform && attachments.length > 0 && (
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
                  className="charkle-pressable inline-flex items-center gap-1.5 px-2.5 py-1 rounded-[var(--win-radius-control)] bg-[var(--accent-soft)] hover:brightness-95 text-[11.5px] font-semibold text-[var(--accent)] disabled:opacity-50 cursor-pointer"
                >
                  <ImageMultiple16Regular className="w-3.5 h-3.5" />
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
                  const canUseCachedLocalVideo =
                    idx === 0 &&
                    asset.isLocalOriginalCached &&
                    /\.(mp4|mov|webm|m4v)$/i.test(asset.fileName) &&
                    !localVideoFailedKeys[key];
                  const videoSrc = canUseCachedLocalVideo
                    ? getTransport().originalUrl(asset.id)
                    : resolvedMediaUrl;

                  return (
                    <div key={key} className="flex flex-col gap-1.5">
                      {mediaFailed ? (
                        <div className="w-full h-[200px] rounded-[var(--win-radius-card)] bg-[var(--bg-subtle)] border border-[var(--win-stroke-card)] flex flex-col items-center justify-center gap-2 text-[12px] text-[var(--text-secondary)]">
                          <VideoClip24Regular className="w-6 h-6 text-[var(--text-tertiary)]" />
                          <span>视频暂时无法在线加载</span>
                          <div className="flex items-center gap-3">
                            <button
                              type="button"
                              disabled={retrying}
                              onClick={() => void handleRefreshPost()}
                              className="inline-flex items-center gap-1 text-[var(--accent)] font-medium hover:underline disabled:opacity-50 cursor-pointer"
                            >
                              <ArrowSync16Regular
                                className={`w-3.5 h-3.5 ${retrying ? 'animate-spin' : ''}`}
                              />
                              <span>重试获取</span>
                            </button>
                            <button
                              type="button"
                              onClick={openOriginalPost}
                              className="text-[var(--accent)] font-medium hover:underline cursor-pointer"
                            >
                              {platform.openLabel}
                            </button>
                          </div>
                        </div>
                      ) : (
                        <SocialAttachmentVideo
                          src={videoSrc}
                          poster={resolvedThumbUrl}
                          videoElRef={idx === 0 ? primaryVideoRef : undefined}
                          onError={() => {
                            if (canUseCachedLocalVideo && resolvedMediaUrl) {
                              setLocalVideoFailedKeys((prev) => ({ ...prev, [key]: true }));
                            } else {
                              setFailedMediaKeys((prev) => ({ ...prev, [key]: true }));
                            }
                          }}
                        />
                      )}
                      <div className="flex items-center justify-between gap-2 flex-wrap">
                        <span className="inline-flex items-center gap-1 text-[11.5px] font-medium text-[var(--text-secondary)]">
                          <VideoClip16Regular className="w-3.5 h-3.5" />
                          {att.kind === 'gif' ? '动图媒体' : '视频媒体'}
                        </span>
                        <div className="flex items-center gap-1.5">
                          {idx === 0 && !mediaFailed && (
                            <button
                              type="button"
                              data-testid="social-video-set-cover-btn"
                              disabled={capturingInlineCover}
                              onClick={() => void handleCapturePrimaryInlineVideoCover()}
                              className="charkle-pressable inline-flex items-center gap-1 px-2.5 py-1 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)] hover:bg-[var(--win-subtle-hover)] text-[11.5px] font-semibold text-[var(--text-primary)] disabled:opacity-50 cursor-pointer"
                            >
                              <Camera16Regular className="w-3.5 h-3.5" />
                              <span>{capturingInlineCover ? '截取中…' : '设当前帧为封面'}</span>
                            </button>
                          )}
                          <button
                            type="button"
                            disabled={extractingKey !== null}
                            onClick={() => void handleExtractOne(att, idx)}
                            className="charkle-pressable inline-flex items-center gap-1 px-2.5 py-1 rounded-[var(--win-radius-control)] bg-[var(--accent-soft)] hover:brightness-95 text-[11.5px] font-semibold text-[var(--accent)] disabled:opacity-50 cursor-pointer"
                          >
                            <VideoClip16Regular className="w-3.5 h-3.5" />
                            <span>{extractingKey === key ? '提取中…' : extractLabel}</span>
                          </button>
                        </div>
                      </div>
                    </div>
                  );
                }

                // Prefer high-res original photo URL, automatically falling back to thumbnailURL on error
                const useThumbFallback = Boolean(fallbackThumbKeys[key]);
                const hasDistinctThumb = Boolean(
                  resolvedThumbUrl && resolvedThumbUrl !== resolvedMediaUrl,
                );
                const photoSrc =
                  useThumbFallback && hasDistinctThumb
                    ? resolvedThumbUrl
                    : resolvedMediaUrl || resolvedThumbUrl;

                return (
                  <div
                    key={key}
                    className={[
                      'relative rounded-[var(--win-radius-card)] overflow-hidden bg-[var(--bg-subtle)]/70 border border-[var(--win-stroke-card)]',
                      isXiaohongshuMultiGrid ? 'aspect-[3/4]' : '',
                    ].join(' ')}
                  >
                    {mediaFailed || !photoSrc ? (
                      <div className="w-full min-h-[180px] h-full flex flex-col items-center justify-center gap-2 p-4 text-center text-[11.5px] text-[var(--text-secondary)]">
                        <ImageOff20Regular className="w-5 h-5 text-[var(--text-tertiary)]" />
                        <span>原图链接已失效或受防盗链限制</span>
                        <button
                          type="button"
                          disabled={retrying}
                          onClick={() => void handleRefreshPost()}
                          className="inline-flex items-center gap-1 text-[var(--accent)] font-medium hover:underline disabled:opacity-50 cursor-pointer"
                        >
                          <ArrowSync16Regular
                            className={`w-3.5 h-3.5 ${retrying ? 'animate-spin' : ''}`}
                          />
                          <span>重试获取</span>
                        </button>
                      </div>
                    ) : (
                      <img
                        src={photoSrc}
                        alt=""
                        referrerPolicy="no-referrer"
                        onError={() => {
                          if (!useThumbFallback && hasDistinctThumb) {
                            setFallbackThumbKeys((prev) => ({ ...prev, [key]: true }));
                          } else {
                            setFailedMediaKeys((prev) => ({ ...prev, [key]: true }));
                          }
                        }}
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
                      className="charkle-pressable absolute bottom-2.5 right-2.5 inline-flex items-center gap-1 px-2.5 py-1 rounded-[var(--win-radius-control)] bg-black/75 hover:bg-black/88 text-white text-[11.5px] font-medium disabled:opacity-50 cursor-pointer"
                    >
                      <ImageAdd20Regular className="w-3.5 h-3.5" />
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
          <div className="flex flex-col items-start gap-2 p-3 rounded-[var(--win-radius-card)] bg-[var(--bg-subtle)]">
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
              onClick={() => void handleRefreshPost()}
              className="charkle-pressable inline-flex items-center gap-1.5 px-3 py-1.5 rounded-[var(--win-radius-control)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-[var(--accent-text)] text-[12px] font-medium disabled:opacity-50 cursor-pointer"
            >
              <ArrowSync16Regular className={`w-3.5 h-3.5 ${retrying ? 'animate-spin' : ''}`} />
              <span>重试获取</span>
            </button>
          </div>
        )}

        <div className="h-px bg-[var(--win-stroke-divider)]" />

        {/* Engagement Counts + Refresh + Open Original */}
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
            disabled={retrying}
            title={`重新解析${platform.noun}正文与图片`}
            onClick={() => void handleRefreshPost()}
            className="inline-flex items-center gap-1 text-[12px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] disabled:opacity-50 cursor-pointer"
          >
            <ArrowSync16Regular className={`w-3.5 h-3.5 ${retrying ? 'animate-spin' : ''}`} />
            <span>{retrying ? '解析中…' : '刷新解析'}</span>
          </button>

          <button
            type="button"
            onClick={openOriginalPost}
            className="inline-flex items-center gap-1 text-[12.5px] font-semibold text-[var(--accent)] hover:underline cursor-pointer"
          >
            <span>{platform.openLabel}</span>
            <Open16Regular className="w-3.5 h-3.5" />
          </button>
        </div>
      </div>
    </div>
  );
};
