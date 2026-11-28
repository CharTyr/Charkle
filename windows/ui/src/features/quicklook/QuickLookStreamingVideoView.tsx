import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  Camera16Regular,
  Globe16Regular,
  Open16Regular,
  Play16Filled,
  VideoOff24Regular,
} from '@fluentui/react-icons';
import { getTransport, isTauriRuntime } from '../../api/transport';
import { isAllowedVideoEmbedUrl } from '../../design-system';
import type { VideoDirectStream, VideoStreamPlaybackPlan } from '../../types/domain';

export interface CapturedVideoFrame {
  imageBase64: string;
  timestampSeconds: number | null;
}

/**
 * Captures the currently decoded frame from an HTML5 `<video>` element onto an offscreen canvas
 * and encodes a bounded JPEG (max 1600px side) without triggering any network download.
 */
export function captureVideoElementFrameJpeg(
  video: HTMLVideoElement | null,
): CapturedVideoFrame | null {
  if (!video) return null;
  const vw = video.videoWidth || 0;
  const vh = video.videoHeight || 0;
  if (vw <= 0 || vh <= 0) return null;

  const maxSide = 1600;
  const scale = Math.max(vw, vh) > maxSide ? maxSide / Math.max(vw, vh) : 1;
  const targetW = Math.max(1, Math.round(vw * scale));
  const targetH = Math.max(1, Math.round(vh * scale));

  const canvas = document.createElement('canvas');
  canvas.width = targetW;
  canvas.height = targetH;
  const ctx = canvas.getContext('2d');
  if (!ctx) return null;

  try {
    ctx.drawImage(video, 0, 0, targetW, targetH);
    const dataUrl = canvas.toDataURL('image/jpeg', 0.9);
    if (!dataUrl || !dataUrl.startsWith('data:image/jpeg;base64,')) {
      return null;
    }
    const base64 = dataUrl.slice('data:image/jpeg;base64,'.length);
    if (!base64) return null;
    const ts = Number.isFinite(video.currentTime) ? Math.max(0, video.currentTime) : 0;
    return { imageBase64: base64, timestampSeconds: ts };
  } catch {
    return null;
  }
}

function inferUaPreset(
  headers: Record<string, string>,
): 'browser' | 'ios-youtube' | 'android-youtube' {
  const ua = (headers['User-Agent'] ?? headers['user-agent'] ?? '').toLowerCase();
  if (ua.includes('ios.youtube')) return 'ios-youtube';
  if (ua.includes('android.youtube')) return 'android-youtube';
  return 'browser';
}

function supportsNativeHlsPlayback(): boolean {
  if (typeof document === 'undefined') return false;
  try {
    const probe = document.createElement('video');
    if (typeof probe.canPlayType !== 'function') return false;
    return probe.canPlayType('application/vnd.apple.mpegurl') !== '';
  } catch {
    return false;
  }
}

export interface QuickLookStreamingVideoViewProps {
  assetId: string;
  playbackKey: string;
  coverSrc?: string;
  coverAlt: string;
  durationText?: string | null;
  watchUrl?: string | null;
  openActionLabel: string;
  onOpenExternal?: () => void;
  onSetCoverFrame?: (frame: CapturedVideoFrame) => Promise<void> | void;
  debounceMs?: number;
}

/**
 * Zero-download inline streaming video player for Quick Look (YouTube, Bilibili, Vimeo,
 * Dailymotion, and video-bearing rich webpages):
 * - Debounces playback-plan resolution (~120ms) so fast arrow-key scrubbing skips wasted lookups.
 * - Tier 1: Native HTML5 `<video>` backed by `charkle-media://localhost/proxy-video-stream`
 *   (bounded 2–4 MiB HTTP Range chunks with required `Referer` + `User-Agent`, zero disk save).
 * - Tier 2: Official embedded `<iframe>` player with `strict-origin-when-cross-origin` Referer
 *   policy and YouTube `origin=https://charkle.app` (prevents Error 153).
 * - Supports "设当前帧为封面" in BOTH native `<video>` mode (offscreen canvas + `MM:SS` playhead)
 *   and `<iframe>` embed mode (WebView2 `CapturePreview` cropped to the player bounding rect).
 * - Releases all media handles immediately on unmount or asset switch (`0%` idle CPU).
 */
export const QuickLookStreamingVideoView: React.FC<QuickLookStreamingVideoViewProps> = ({
  assetId,
  playbackKey,
  coverSrc,
  coverAlt,
  durationText,
  watchUrl,
  openActionLabel,
  onOpenExternal,
  onSetCoverFrame,
  debounceMs = 120,
}) => {
  const [plan, setPlan] = useState<VideoStreamPlaybackPlan | null>(null);
  const [isResolving, setIsResolving] = useState(true);
  const [directStreamIndex, setDirectStreamIndex] = useState(0);
  const [useEmbedMode, setUseEmbedMode] = useState(false);
  const [allDirectStreamsFailed, setAllDirectStreamsFailed] = useState(false);
  const [isCapturingCover, setIsCapturingCover] = useState(false);
  const [hideControlsForCapture, setHideControlsForCapture] = useState(false);
  const [coverFailed, setCoverFailed] = useState(false);

  const stageRef = useRef<HTMLDivElement | null>(null);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const iframeRef = useRef<HTMLIFrameElement | null>(null);
  const latestPlaybackKeyRef = useRef<string>(`${assetId}:${playbackKey}`);
  latestPlaybackKeyRef.current = `${assetId}:${playbackKey}`;

  const nativeHlsSupported = useMemo(() => supportsNativeHlsPlayback(), []);

  const playableDirectStreams: VideoDirectStream[] = useMemo(() => {
    if (!plan) return [];
    return plan.directStreams.filter((s) => !s.isHls || nativeHlsSupported);
  }, [plan, nativeHlsSupported]);

  // Debounced playback plan resolution
  useEffect(() => {
    let cancelled = false;
    setPlan(null);
    setIsResolving(true);
    setDirectStreamIndex(0);
    setUseEmbedMode(false);
    setAllDirectStreamsFailed(false);
    setCoverFailed(false);

    const timer = window.setTimeout(() => {
      void getTransport()
        .resolveVideoPlaybackPlan(assetId)
        .then((resolved) => {
          if (cancelled) return;
          setPlan(resolved);
          const playable = resolved.directStreams.filter((s) => !s.isHls || nativeHlsSupported);
          if (playable.length === 0 && resolved.embedPlayer) {
            setUseEmbedMode(true);
          }
          setIsResolving(false);
        })
        .catch(() => {
          if (cancelled) return;
          setPlan({ directStreams: [], embedPlayer: null, watchUrl: watchUrl ?? null });
          setIsResolving(false);
        });
    }, debounceMs);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [assetId, playbackKey, debounceMs, nativeHlsSupported, watchUrl]);

  const activeDirectStream: VideoDirectStream | null =
    !useEmbedMode &&
    !allDirectStreamsFailed &&
    directStreamIndex >= 0 &&
    directStreamIndex < playableDirectStreams.length
      ? playableDirectStreams[directStreamIndex]
      : null;

  const safeEmbedPlayer =
    plan?.embedPlayer && isAllowedVideoEmbedUrl(plan.embedPlayer.url) ? plan.embedPlayer : null;

  const activeEmbed =
    !activeDirectStream &&
    safeEmbedPlayer &&
    (useEmbedMode || allDirectStreamsFailed || playableDirectStreams.length === 0)
      ? safeEmbedPlayer
      : null;

  const directVideoSrc = useMemo(() => {
    if (!activeDirectStream) return undefined;
    const referer =
      activeDirectStream.httpHeaders.Referer ?? activeDirectStream.httpHeaders.referer ?? null;
    const uaPreset = inferUaPreset(activeDirectStream.httpHeaders);
    return isTauriRuntime()
      ? getTransport().videoStreamProxyUrl(activeDirectStream.url, { referer, uaPreset })
      : activeDirectStream.url;
  }, [activeDirectStream]);

  // Strict teardown for HTML5 <video> and <iframe> so closing Quick Look or switching assets
  // never leaves audio/video decoding running in the background.
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
  }, [directVideoSrc, playbackKey]);

  useEffect(() => {
    const frame = iframeRef.current;
    return () => {
      if (frame) {
        try {
          frame.src = 'about:blank';
        } catch {
          // Ignore teardown errors
        }
      }
    };
  }, [activeEmbed?.url, playbackKey]);

  const canToggleModes = Boolean(
    playableDirectStreams.length > 0 && !allDirectStreamsFailed && safeEmbedPlayer,
  );
  const isPlayerMounted = Boolean(activeDirectStream || activeEmbed);
  const hasPlayableSource = Boolean(playableDirectStreams.length > 0 || safeEmbedPlayer);

  const handleDirectStreamError = () => {
    if (directStreamIndex + 1 < playableDirectStreams.length) {
      setDirectStreamIndex((i) => i + 1);
    } else {
      setAllDirectStreamsFailed(true);
      if (safeEmbedPlayer) {
        setUseEmbedMode(true);
      }
    }
  };

  const handleCaptureCover = async () => {
    if (!onSetCoverFrame || isCapturingCover) return;
    const captureKey = latestPlaybackKeyRef.current;
    setIsCapturingCover(true);
    try {
      // 1. Direct HTML5 <video> frame capture via offscreen canvas (preserves exact MM:SS playhead)
      if (activeDirectStream && videoRef.current) {
        const directFrame = captureVideoElementFrameJpeg(videoRef.current);
        if (directFrame) {
          if (latestPlaybackKeyRef.current !== captureKey) return;
          await onSetCoverFrame(directFrame);
          return;
        }
      }

      // 2. Fallback / Embed iframe capture via native WebView2 CapturePreview cropped to stage rect
      const stageEl = stageRef.current;
      if (!stageEl) return;
      const rect = stageEl.getBoundingClientRect();
      if (rect.width < 8 || rect.height < 8) return;

      // Hide floating top-right pills cleanly before capturing the composited frame
      setHideControlsForCapture(true);
      await new Promise<void>((resolve) => {
        if (typeof window !== 'undefined' && typeof window.requestAnimationFrame === 'function') {
          window.requestAnimationFrame(() => window.requestAnimationFrame(() => resolve()));
        } else {
          setTimeout(resolve, 16);
        }
      });

      if (latestPlaybackKeyRef.current !== captureKey) return;
      const dpr = typeof window !== 'undefined' && window.devicePixelRatio > 0 ? window.devicePixelRatio : 1;
      const jpegBase64 = await getTransport().captureWebviewRegionJpeg(
        rect.left,
        rect.top,
        rect.width,
        rect.height,
        dpr,
      );
      setHideControlsForCapture(false);
      if (latestPlaybackKeyRef.current !== captureKey) return;
      if (jpegBase64) {
        const ts =
          activeDirectStream && videoRef.current && Number.isFinite(videoRef.current.currentTime)
            ? Math.max(0, videoRef.current.currentTime)
            : null;
        await onSetCoverFrame({ imageBase64: jpegBase64, timestampSeconds: ts });
      }
    } finally {
      setHideControlsForCapture(false);
      setIsCapturingCover(false);
    }
  };

  const renderCoverSurface = () => (
    <div className="relative w-full h-full bg-black">
      {coverSrc && !coverFailed ? (
        <img
          src={coverSrc}
          alt={coverAlt}
          referrerPolicy="no-referrer"
          onError={() => setCoverFailed(true)}
          className="w-full h-full object-cover"
        />
      ) : (
        <div className="w-full h-full bg-black/90" />
      )}
      {durationText && (
        <span className="absolute bottom-2.5 right-2.5 px-2 py-0.5 rounded-[var(--win-radius-control)] bg-black/80 text-white text-[11.5px] font-semibold charkle-mono">
          {durationText}
        </span>
      )}
    </div>
  );

  return (
    <div
      ref={stageRef}
      data-testid="quicklook-streaming-video-player"
      className="relative aspect-video w-full rounded-[var(--win-radius-card)] overflow-hidden bg-black border border-[var(--win-stroke-card)]"
    >
      {/* Active Player Layer */}
      {!isResolving && activeDirectStream && directVideoSrc ? (
        <video
          ref={videoRef}
          key={`${playbackKey}:direct:${directStreamIndex}`}
          data-testid="streaming-native-video"
          src={directVideoSrc}
          poster={coverSrc}
          crossOrigin="anonymous"
          controls
          autoPlay
          playsInline
          onError={handleDirectStreamError}
          className="w-full h-full bg-black object-contain"
        />
      ) : !isResolving && activeEmbed ? (
        <iframe
          ref={iframeRef}
          key={`${playbackKey}:embed:${activeEmbed.url}`}
          data-testid="streaming-embed-iframe"
          title={coverAlt}
          src={activeEmbed.url}
          referrerPolicy="strict-origin-when-cross-origin"
          sandbox="allow-scripts allow-same-origin allow-presentation allow-popups"
          allow="accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture; web-share; fullscreen"
          allowFullScreen
          className="w-full h-full border-0 bg-black"
        />
      ) : (
        renderCoverSurface()
      )}

      {/* Resolving Overlay */}
      {isResolving && (
        <div className="absolute inset-0 flex items-center justify-center pointer-events-none">
          <div className="win-acrylic-dark inline-flex items-center gap-2 px-3.5 py-2 rounded-full text-[12.5px] font-semibold">
            <span className="w-3.5 h-3.5 rounded-full border-2 border-white/30 border-t-white animate-spin motion-reduce:animate-none" />
            <span>正在连接流式播放…</span>
          </div>
        </div>
      )}

      {/* Unplayable Fallback Overlay */}
      {!isResolving && !hasPlayableSource && (
        <div className="absolute inset-0 flex items-center justify-center">
          <div className="win-acrylic-dark flex flex-col items-center gap-2.5 px-5 py-4 rounded-[14px] text-center">
            <VideoOff24Regular className="w-6 h-6 text-white/85" />
            <span className="text-[12.5px] font-medium text-white/92">
              暂无法直接流式播放此视频
            </span>
            {watchUrl && onOpenExternal && (
              <button
                type="button"
                onClick={onOpenExternal}
                className="charkle-pressable inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-[var(--accent-text)] text-[12px] font-semibold cursor-pointer"
              >
                <Open16Regular className="w-3.5 h-3.5" />
                <span>{openActionLabel}</span>
              </button>
            )}
          </div>
        </div>
      )}

      {/* Top-Right Floating Controls ("设当前帧为封面" + Tier 1/Tier 2 Player Switch) */}
      {!isResolving &&
        isPlayerMounted &&
        !hideControlsForCapture &&
        (canToggleModes || Boolean(onSetCoverFrame)) && (
          <div className="absolute top-2.5 right-2.5 z-10 flex items-center gap-1.5">
            {onSetCoverFrame && (
              <button
                type="button"
                data-testid="streaming-set-cover-btn"
                disabled={isCapturingCover}
                title="截取当前播放画面作为此素材封面"
                onClick={() => void handleCaptureCover()}
                className="win-acrylic-dark charkle-pressable inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-semibold hover:brightness-110 disabled:opacity-60 cursor-pointer"
              >
                <Camera16Regular className="w-3.5 h-3.5" />
                <span>{isCapturingCover ? '截取中…' : '设当前帧为封面'}</span>
              </button>
            )}
            {canToggleModes && (
              <button
                type="button"
                data-testid="streaming-toggle-mode-btn"
                onClick={() => setUseEmbedMode((v) => !v)}
                className="win-acrylic-dark charkle-pressable inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-semibold hover:brightness-110 cursor-pointer"
              >
                {useEmbedMode ? (
                  <Play16Filled className="w-3 h-3" />
                ) : (
                  <Globe16Regular className="w-3.5 h-3.5" />
                )}
                <span>{useEmbedMode ? '切换原生流式' : '切换网页播放器'}</span>
              </button>
            )}
          </div>
        )}
    </div>
  );
};
