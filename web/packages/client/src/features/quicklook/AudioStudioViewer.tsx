import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Pause, Play, Volume2, VolumeX } from 'lucide-react';
import type { AssetRecord } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { formatDuration } from '../../design-system';

export interface AudioStudioViewerProps {
  asset: AssetRecord;
}

export const AudioStudioViewer: React.FC<AudioStudioViewerProps> = ({ asset }) => {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const waveRef = useRef<HTMLDivElement | null>(null);

  const [playing, setPlaying] = useState(false);
  const [muted, setMuted] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(asset.durationSeconds ?? 0);
  const [scrubbing, setScrubbing] = useState(false);

  const peaks = useMemo(() => {
    if (asset.waveformPeaks.length > 0) {
      return asset.waveformPeaks.slice(0, 64);
    }
    return Array.from({ length: 48 }, (_, i) => 0.25 + 0.65 * Math.abs(Math.sin(i * 0.35)));
  }, [asset.waveformPeaks]);

  const accentColor = asset.dominantColors[0]?.hex || 'var(--accent)';
  const progress = duration > 0 ? Math.max(0, Math.min(1, currentTime / duration)) : 0;

  useEffect(() => {
    setPlaying(false);
    setCurrentTime(0);
    setDuration(asset.durationSeconds ?? 0);
  }, [asset.id, asset.durationSeconds]);

  const togglePlay = () => {
    const audio = audioRef.current;
    if (!audio) return;
    if (playing) {
      audio.pause();
    } else {
      void audio.play().catch(() => {});
    }
  };

  const seekFromClientX = (clientX: number) => {
    const wave = waveRef.current;
    const audio = audioRef.current;
    if (!wave || !audio) return;
    const rect = wave.getBoundingClientRect();
    const frac = Math.max(0, Math.min(1, (clientX - rect.left) / Math.max(1, rect.width)));
    const targetDur = audio.duration && Number.isFinite(audio.duration) ? audio.duration : duration;
    if (targetDur > 0) {
      audio.currentTime = frac * targetDur;
      setCurrentTime(frac * targetDur);
    }
  };

  return (
    <div className="w-[min(580px,90vw)] rounded-[var(--radius-dock-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] shadow-2xl p-6 flex flex-col gap-5 select-none">
      <audio
        ref={audioRef}
        src={apiClient.originalMediaURL(asset.id)}
        muted={muted}
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onEnded={() => setPlaying(false)}
        onTimeUpdate={(e) => {
          if (!scrubbing) setCurrentTime(e.currentTarget.currentTime);
        }}
        onLoadedMetadata={(e) => {
          if (Number.isFinite(e.currentTarget.duration)) {
            setDuration(e.currentTarget.duration);
          }
        }}
      />

      {/* Title & Audio Controls */}
      <div className="flex items-center justify-between gap-3">
        <div className="min-w-0">
          <h3 className="text-[16px] font-semibold text-[var(--text-primary)] truncate">
            {asset.title}
          </h3>
        </div>
        <button
          type="button"
          onClick={() => setMuted((m) => !m)}
          aria-label={muted ? '取消静音' : '静音'}
          className="charkle-pressable h-8 w-8 rounded-full bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] flex items-center justify-center cursor-pointer"
        >
          {muted ? <VolumeX size={15} /> : <Volume2 size={15} />}
        </button>
      </div>

      {/* Scrubbable 48-64 Bar Waveform */}
      <div
        ref={waveRef}
        onMouseDown={(e) => {
          setScrubbing(true);
          seekFromClientX(e.clientX);
          const onMove = (ev: MouseEvent) => seekFromClientX(ev.clientX);
          const onUp = () => {
            setScrubbing(false);
            window.removeEventListener('mousemove', onMove);
            window.removeEventListener('mouseup', onUp);
          };
          window.addEventListener('mousemove', onMove);
          window.addEventListener('mouseup', onUp);
        }}
        className="h-24 flex items-center gap-[3px] px-3 py-3 rounded-[var(--radius-settings-outer)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] cursor-ew-resize"
      >
        {peaks.map((peak, idx) => {
          const barFrac = (idx + 0.5) / peaks.length;
          const played = barFrac <= progress;
          return (
            <div
              key={idx}
              className="flex-1 h-full flex items-center justify-center"
            >
              <span
                className="w-full max-w-[6px] rounded-full transition-colors duration-100"
                style={{
                  height: `${Math.max(14, Math.round(peak * 100))}%`,
                  backgroundColor: played ? accentColor : 'var(--border-strong)',
                }}
              />
            </div>
          );
        })}
      </div>

      {/* Controls & Time Readout */}
      <div className="flex items-center justify-between gap-4">
        <span className="text-[12px] font-mono tabular-nums text-[var(--text-secondary)] w-12">
          {formatDuration(currentTime)}
        </span>

        <button
          type="button"
          onClick={togglePlay}
          aria-label={playing ? '暂停' : '播放'}
          style={{ backgroundColor: accentColor }}
          className="charkle-pressable h-12 w-12 rounded-full text-white shadow-md flex items-center justify-center cursor-pointer"
        >
          {playing ? <Pause size={20} /> : <Play size={20} className="translate-x-0.5" />}
        </button>

        <span className="text-[12px] font-mono tabular-nums text-[var(--text-tertiary)] w-12 text-right">
          {formatDuration(duration)}
        </span>
      </div>
    </div>
  );
};
