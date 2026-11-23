import React, { useEffect, useMemo, useRef, useState } from 'react';
import { AudioWaveform, Pause, Play, Volume2, VolumeX } from 'lucide-react';
import { getTransport } from '../../api/transport';
import { formatDuration } from '../../design-system';
import type { AssetRecord } from '../../types/domain';

export interface AudioStudioViewerProps {
  asset: AssetRecord;
}

/**
 * 48-bar interactive waveform studio audio player (M2-R7).
 */
export const AudioStudioViewer: React.FC<AudioStudioViewerProps> = ({ asset }) => {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const [playing, setPlaying] = useState(false);
  const [muted, setMuted] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(asset.durationSeconds ?? 0);

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
        out.push(0.24 + Math.abs(Math.sin(i * 0.52 + 0.8)) * 0.68);
      }
    }
    return out;
  }, [asset.waveformPeaks]);

  useEffect(() => {
    setPlaying(false);
    setCurrentTime(0);
    setDuration(asset.durationSeconds ?? 0);
  }, [asset.id, asset.durationSeconds]);

  const progress = duration > 0 ? Math.min(1, currentTime / duration) : 0;

  const togglePlay = async () => {
    const el = audioRef.current;
    if (!el) return;
    if (el.paused) {
      try {
        await el.play();
        setPlaying(true);
      } catch {
        setPlaying(false);
      }
    } else {
      el.pause();
      setPlaying(false);
    }
  };

  const seekToRatio = (ratio: number) => {
    const el = audioRef.current;
    if (!el || !duration) return;
    const next = Math.max(0, Math.min(duration, ratio * duration));
    el.currentTime = next;
    setCurrentTime(next);
  };

  return (
    <div className="w-full max-w-[640px] mx-auto p-6 rounded-[var(--radius-dock-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl flex flex-col gap-5">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-3 min-w-0">
          <div className="h-11 w-11 rounded-[var(--radius-dock-inner)] bg-[var(--accent-soft)] text-[var(--accent)] flex items-center justify-center shrink-0">
            <AudioWaveform size={22} />
          </div>
          <div className="min-w-0">
            <div className="text-[15px] font-semibold text-[var(--text-primary)] truncate">
              {asset.title}
            </div>
            <div className="text-[12px] text-[var(--text-secondary)] truncate">
              {asset.fileName}
            </div>
          </div>
        </div>
        <div className="text-[12px] text-[var(--text-secondary)] charkle-tabular shrink-0">
          {formatDuration(currentTime)} / {formatDuration(duration)}
        </div>
      </div>

      {/* 48-bar clickable waveform */}
      <div
        role="slider"
        aria-label="音频进度波形"
        aria-valuemin={0}
        aria-valuemax={Math.round(duration)}
        aria-valuenow={Math.round(currentTime)}
        className="h-[88px] flex items-end gap-[4px] px-1 cursor-pointer select-none"
      >
        {peaks.map((peak, idx) => {
          const ratio = (idx + 0.5) / peaks.length;
          const active = ratio <= progress;
          return (
            <button
              key={idx}
              type="button"
              aria-label={`跳转到 ${Math.round(ratio * 100)}%`}
              onClick={() => seekToRatio(ratio)}
              className={[
                'flex-1 rounded-full transition-colors duration-100 cursor-pointer',
                active ? 'bg-[var(--accent)]' : 'bg-[var(--border-strong)] hover:bg-[var(--accent)]/60',
              ].join(' ')}
              style={{ height: `${Math.max(14, Math.round(peak * 100))}%` }}
            />
          );
        })}
      </div>

      {/* Controls */}
      <div className="flex items-center justify-between">
        <button
          type="button"
          onClick={() => void togglePlay()}
          className="charkle-pressable h-10 px-5 rounded-full bg-[var(--accent)] text-white inline-flex items-center gap-2 text-[13px] font-medium cursor-pointer"
        >
          {playing ? <Pause size={15} /> : <Play size={15} />}
          <span>{playing ? '暂停' : '播放'}</span>
        </button>

        <button
          type="button"
          aria-label={muted ? '取消静音' : '静音'}
          onClick={() => {
            const next = !muted;
            setMuted(next);
            if (audioRef.current) audioRef.current.muted = next;
          }}
          className="charkle-pressable h-9 w-9 rounded-full bg-[var(--bg-subtle)] text-[var(--text-primary)] inline-flex items-center justify-center cursor-pointer"
        >
          {muted ? <VolumeX size={16} /> : <Volume2 size={16} />}
        </button>
      </div>

      <audio
        ref={audioRef}
        src={getTransport().originalUrl(asset.id)}
        onTimeUpdate={(e) => setCurrentTime(e.currentTarget.currentTime)}
        onLoadedMetadata={(e) => {
          if (Number.isFinite(e.currentTarget.duration)) {
            setDuration(e.currentTarget.duration);
          }
        }}
        onEnded={() => setPlaying(false)}
      />
    </div>
  );
};
