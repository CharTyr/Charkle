import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  ErrorCircle16Regular,
  FolderOpen16Regular,
  Pause16Regular,
  Play16Filled,
  Speaker216Regular,
  SpeakerMute16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import { Button, formatDuration, isLightHex } from '../../design-system';
import type { AssetRecord } from '../../types/domain';

export interface AudioStudioViewerProps {
  asset: AssetRecord;
}

function safeFiniteDuration(value: number | null | undefined): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;
}

/**
 * Interactive waveform audio studio card (1:1 macOS `QuickLookAudioStudioCard`)
 * with click & pointer-capture drag scrubbing, keyboard seek, error fallback,
 * and guaranteed audio pause/release on asset switch and unmount.
 */
export const AudioStudioViewer: React.FC<AudioStudioViewerProps> = ({ asset }) => {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const waveRef = useRef<HTMLDivElement | null>(null);
  const scrubbingRef = useRef<number | null>(null);

  const [playing, setPlaying] = useState(false);
  const [muted, setMuted] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(() => safeFiniteDuration(asset.durationSeconds));
  const [playbackError, setPlaybackError] = useState<string | null>(null);

  const accentHex = asset.dominantColors[0]?.hex ?? '#3D5A80';
  const playButtonTextColor = isLightHex(accentHex) ? 'rgba(0,0,0,0.86)' : '#ffffff';

  const peaks = useMemo(() => {
    const target = 48;
    if (asset.waveformPeaks.length >= target) {
      return asset.waveformPeaks.slice(0, target);
    }
    const out: number[] = [];
    for (let i = 0; i < target; i++) {
      if (asset.waveformPeaks.length > 0) {
        const idx = Math.floor((i / target) * asset.waveformPeaks.length);
        out.push(asset.waveformPeaks[idx]);
      } else {
        out.push(0.25 + Math.abs(Math.sin(i * 0.35)) * 0.65);
      }
    }
    return out;
  }, [asset.waveformPeaks]);

  // Pause & reset <audio> immediately on asset switch AND release on unmount (no phantom audio leak)
  useEffect(() => {
    const el = audioRef.current;
    if (el) {
      el.pause();
      try {
        el.currentTime = 0;
      } catch {
        // Ignore seek errors before metadata loads
      }
      el.muted = muted;
    }
    scrubbingRef.current = null;
    setPlaying(false);
    setCurrentTime(0);
    setDuration(safeFiniteDuration(asset.durationSeconds));
    setPlaybackError(null);
  }, [asset.id, asset.durationSeconds]);

  useEffect(() => {
    const el = audioRef.current;
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
  }, []);

  const safeCurrentTime = safeFiniteDuration(currentTime);
  const safeDuration = safeFiniteDuration(duration);
  const progress = safeDuration > 0 ? Math.min(1, safeCurrentTime / safeDuration) : 0;

  const togglePlay = async () => {
    const el = audioRef.current;
    if (!el || playbackError) return;
    if (el.paused) {
      try {
        setPlaybackError(null);
        await el.play();
        setPlaying(true);
      } catch (err) {
        setPlaying(false);
        const isAbort =
          (typeof DOMException !== 'undefined' &&
            err instanceof DOMException &&
            err.name === 'AbortError') ||
          (typeof err === 'object' &&
            err !== null &&
            'name' in err &&
            (err as { name?: unknown }).name === 'AbortError');
        if (!isAbort) {
          setPlaybackError('当前音频暂无法直接播放，可在资源管理器中打开');
        }
      }
    } else {
      el.pause();
      setPlaying(false);
    }
  };

  const seekToSeconds = (targetSeconds: number) => {
    const el = audioRef.current;
    if (!el) return;
    const effectiveDur = safeDuration || safeFiniteDuration(el.duration);
    if (effectiveDur <= 0) return;
    const clamped = Math.max(0, Math.min(effectiveDur, targetSeconds));
    el.currentTime = clamped;
    setCurrentTime(clamped);
  };

  const seekByClientX = (clientX: number) => {
    const el = audioRef.current;
    const wave = waveRef.current;
    if (!wave || !el) return;
    const rect = wave.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (clientX - rect.left) / Math.max(1, rect.width)));
    const effectiveDur = safeDuration || safeFiniteDuration(el.duration);
    if (effectiveDur > 0) {
      seekToSeconds(ratio * effectiveDur);
    }
  };

  return (
    <div
      onClick={(e) => e.stopPropagation()}
      className="w-full max-w-[580px] mx-auto p-6 rounded-[var(--win-radius-dialog)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-flyout)] shadow-[0_24px_60px_rgba(0,0,0,0.40)] flex flex-col gap-5"
    >
      <div className="flex items-center gap-3">
        <button
          type="button"
          disabled={Boolean(playbackError)}
          aria-label={playing ? '暂停播放' : '开始播放'}
          onClick={() => void togglePlay()}
          style={{ backgroundColor: accentHex, color: playButtonTextColor }}
          className="charkle-pressable w-11 h-11 rounded-full inline-flex items-center justify-center shrink-0 cursor-pointer disabled:opacity-45"
        >
          {playing ? (
            <Pause16Regular className="w-5 h-5" />
          ) : (
            <Play16Filled className="w-5 h-5 translate-x-[1px]" />
          )}
        </button>

        <div className="min-w-0 flex-1">
          <div className="text-[16px] font-semibold text-[var(--text-primary)] truncate">
            {asset.title}
          </div>
          <div className="text-[12px] text-[var(--text-secondary)] truncate mt-0.5">
            {playbackError ? '音频解码受限' : '音频原文件就绪 · 点击或拖动波形可跳转'}
          </div>
        </div>

        <div className="flex items-center gap-2 shrink-0">
          <span className="text-[12px] font-semibold charkle-mono charkle-tabular text-[var(--text-secondary)]">
            {formatDuration(safeCurrentTime)} / {formatDuration(safeDuration)}
          </span>
          <button
            type="button"
            aria-label={muted ? '取消静音' : '静音'}
            onClick={() => {
              const next = !muted;
              setMuted(next);
              if (audioRef.current) audioRef.current.muted = next;
            }}
            className="charkle-pressable h-8 w-8 rounded-[var(--win-radius-control)] bg-[var(--win-subtle-hover)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-active)] inline-flex items-center justify-center cursor-pointer"
          >
            {muted ? (
              <SpeakerMute16Regular className="w-4 h-4" />
            ) : (
              <Speaker216Regular className="w-4 h-4" />
            )}
          </button>
        </div>
      </div>

      {playbackError && (
        <div className="flex items-center justify-between gap-3 px-3.5 py-2.5 rounded-[var(--win-radius-card)] bg-[var(--danger-soft)]/70 border border-[var(--danger)]/25 text-[12px] text-[var(--danger)]">
          <span className="inline-flex items-center gap-2 min-w-0">
            <ErrorCircle16Regular className="w-4 h-4 shrink-0" />
            <span className="truncate">{playbackError}</span>
          </span>
          <Button
            variant="standard"
            size="xs"
            onClick={() => void getTransport().revealInExplorer(asset.id)}
          >
            <FolderOpen16Regular className="w-3.5 h-3.5" />
            定位文件
          </Button>
        </div>
      )}

      {/* 48-bar interactive waveform with click, drag & keyboard scrub */}
      <div
        ref={waveRef}
        role="slider"
        tabIndex={0}
        aria-label="音频进度波形"
        aria-valuemin={0}
        aria-valuemax={Math.round(safeDuration)}
        aria-valuenow={Math.round(safeCurrentTime)}
        onKeyDown={(e) => {
          const step = Math.max(5, Math.round(safeDuration * 0.05));
          if (e.key === 'ArrowLeft') {
            e.preventDefault();
            e.stopPropagation();
            seekToSeconds(safeCurrentTime - step);
          } else if (e.key === 'ArrowRight') {
            e.preventDefault();
            e.stopPropagation();
            seekToSeconds(safeCurrentTime + step);
          } else if (e.key === 'Home') {
            e.preventDefault();
            e.stopPropagation();
            seekToSeconds(0);
          } else if (e.key === 'End') {
            e.preventDefault();
            e.stopPropagation();
            seekToSeconds(safeDuration);
          }
        }}
        onPointerDown={(e) => {
          if (e.button !== 0 || playbackError) return;
          e.preventDefault();
          scrubbingRef.current = e.pointerId;
          try {
            e.currentTarget.setPointerCapture?.(e.pointerId);
          } catch {
            // Ignore synthetic events
          }
          seekByClientX(e.clientX);
        }}
        onPointerMove={(e) => {
          if (scrubbingRef.current !== e.pointerId) return;
          seekByClientX(e.clientX);
        }}
        onPointerUp={(e) => {
          if (scrubbingRef.current === e.pointerId) {
            scrubbingRef.current = null;
          }
        }}
        onPointerCancel={() => {
          scrubbingRef.current = null;
        }}
        className="h-[76px] flex items-center gap-[3px] px-0.5 cursor-pointer select-none outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent)] rounded-[8px]"
      >
        {peaks.map((peak, idx) => {
          const frac = idx / Math.max(1, peaks.length - 1);
          const active = frac <= progress;
          const heightPct = Math.max(15, Math.min(100, Math.round(peak * 100)));
          return (
            <span
              key={idx}
              style={{
                height: `${heightPct}%`,
                backgroundColor: active ? accentHex : undefined,
              }}
              className={[
                'flex-1 rounded-full transition-colors duration-100',
                active ? '' : 'bg-[var(--text-primary)]/18',
              ].join(' ')}
            />
          );
        })}
      </div>

      <audio
        ref={audioRef}
        src={getTransport().originalUrl(asset.id)}
        muted={muted}
        onTimeUpdate={(e) => setCurrentTime(safeFiniteDuration(e.currentTarget.currentTime))}
        onLoadedMetadata={(e) => {
          const dur = safeFiniteDuration(e.currentTarget.duration);
          if (dur > 0) setDuration(dur);
        }}
        onPause={() => setPlaying(false)}
        onPlay={() => {
          setPlaybackError(null);
          setPlaying(true);
        }}
        onEnded={() => setPlaying(false)}
        onError={() => {
          setPlaying(false);
          setPlaybackError('无法加载该音频文件，可能格式不受支持或原文件尚未缓存');
        }}
      />
    </div>
  );
};
