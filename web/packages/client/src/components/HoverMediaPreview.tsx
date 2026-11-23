import React, { useCallback, useEffect, useRef, useState } from 'react';
import { VolumeX } from 'lucide-react';
import type { AssetRecord } from '@charkle/shared';
import { apiClient } from '../api/client';
import { useCoordinatorStore } from '../stores/coordinatorStore';
import {
  claimHoverPreview,
  hasRecentUncachedHoverMiss,
  isFineHoverPointer,
  isLiveScrolling,
  markUncachedHoverMiss,
  prefersReducedMotion,
  releaseHoverPreview,
  stopAllHoverPreviews,
  supportsHoverPlayback,
} from './hoverMediaCoordinator';

export {
  supportsHoverPlayback,
  stopAllHoverPreviews,
  notifyLiveScrolling,
} from './hoverMediaCoordinator';

const DWELL_DELAY_MS = 140;
const MIN_PLAYBACK_SIZE = 32;
const MIN_BADGE_WIDTH = 92;
const MIN_BADGE_HEIGHT = 64;

export interface HoverMediaPreviewProps {
  asset: AssetRecord;
  active: boolean;
  fit?: 'cover' | 'contain';
  roundedClass?: string;
  showMutedBadge?: boolean;
  badgePosition?: 'top-right' | 'top-left' | 'bottom-left';
  disabled?: boolean;
  className?: string;
  onRevealChange?: (revealed: boolean) => void;
}

export const HoverMediaPreview: React.FC<HoverMediaPreviewProps> = React.memo(
  ({
    asset,
    active,
    fit = 'cover',
    roundedClass = '',
    showMutedBadge = true,
    badgePosition = 'top-right',
    disabled = false,
    className = '',
    onRevealChange,
  }) => {
    const quickLookOpen = useCoordinatorStore((s) => s.quickLookAssetID !== null);
    const containerRef = useRef<HTMLDivElement | null>(null);
    const videoRef = useRef<HTMLVideoElement | null>(null);
    const tokenRef = useRef<symbol | null>(null);
    const timerRef = useRef<number | null>(null);
    const onRevealChangeRef = useRef(onRevealChange);
    onRevealChangeRef.current = onRevealChange;

    const [armed, setArmed] = useState(false);
    const [revealed, setRevealed] = useState(false);
    const [fitsBadge, setFitsBadge] = useState(false);

    const eligible =
      active &&
      !disabled &&
      !quickLookOpen &&
      supportsHoverPlayback(asset) &&
      !prefersReducedMotion() &&
      isFineHoverPointer();

    const cacheKey = `${asset.id}:${asset.updatedAt}`;

    const teardown = useCallback(() => {
      if (timerRef.current !== null) {
        window.clearTimeout(timerRef.current);
        timerRef.current = null;
      }
      const video = videoRef.current;
      if (video) {
        try {
          video.pause();
          video.removeAttribute('src');
          video.load();
        } catch {
          // Ignore media teardown errors
        }
      }
      if (tokenRef.current) {
        releaseHoverPreview(tokenRef.current);
        tokenRef.current = null;
      }
      setArmed(false);
      setRevealed(false);
      onRevealChangeRef.current?.(false);
    }, []);

    useEffect(() => {
      if (!eligible) {
        teardown();
        return;
      }
      if (hasRecentUncachedHoverMiss(cacheKey)) {
        return;
      }

      const token = Symbol(`hover-${asset.id}`);
      tokenRef.current = token;

      timerRef.current = window.setTimeout(() => {
        timerRef.current = null;
        if (tokenRef.current !== token) return;
        if (useCoordinatorStore.getState().quickLookAssetID !== null) return;
        if (isLiveScrolling()) return;

        const el = containerRef.current;
        if (!el) return;
        const rect = el.getBoundingClientRect();
        if (rect.width < MIN_PLAYBACK_SIZE || rect.height < MIN_PLAYBACK_SIZE) {
          return;
        }

        const claimed = claimHoverPreview(token, () => {
          // Called synchronously when another card claims hover playback or scroll/click occurs
          const video = videoRef.current;
          if (video) {
            try {
              video.pause();
              video.removeAttribute('src');
              video.load();
            } catch {
              // Ignore
            }
          }
          if (tokenRef.current === token) {
            tokenRef.current = null;
          }
          setArmed(false);
          setRevealed(false);
          onRevealChangeRef.current?.(false);
        });

        if (!claimed) return;

        setFitsBadge(rect.width >= MIN_BADGE_WIDTH && rect.height >= MIN_BADGE_HEIGHT);
        setRevealed(false);
        setArmed(true);
      }, DWELL_DELAY_MS);

      return () => {
        teardown();
      };
    }, [eligible, asset.id, cacheKey, teardown]);

    useEffect(() => {
      if (!armed || asset.mediaKind !== 'video') return;
      const video = videoRef.current;
      if (!video) return;
      video.muted = true;
      video.defaultMuted = true;
      video.volume = 0;
      const playPromise = video.play();
      if (playPromise && typeof playPromise.catch === 'function') {
        playPromise.catch(() => {
          // Autoplay blocked or aborted during fast hover sweep — stay silently on thumbnail
        });
      }
    }, [armed, asset.mediaKind]);

    const handleVideoReady = useCallback((e: React.SyntheticEvent<HTMLVideoElement>) => {
      const video = e.currentTarget;
      video.muted = true;
      video.volume = 0;
      if (video.readyState >= 2) {
        setRevealed(true);
        onRevealChangeRef.current?.(true);
      }
    }, []);

    const handleImageReady = useCallback(() => {
      setRevealed(true);
      onRevealChangeRef.current?.(true);
    }, []);

    const handleMediaError = useCallback(() => {
      markUncachedHoverMiss(cacheKey);
      teardown();
    }, [cacheKey, teardown]);

    if (!supportsHoverPlayback(asset)) {
      return null;
    }

    const src = armed ? apiClient.originalMediaURL(asset.id, { cachedOnly: true }) : '';
    const fitClass = fit === 'contain' ? 'object-contain' : 'object-cover';
    const badgePosClass =
      badgePosition === 'top-left'
        ? 'top-1.5 left-1.5'
        : badgePosition === 'bottom-left'
          ? 'bottom-2 left-2'
          : 'top-1.5 right-1.5';

    return (
      <div
        ref={containerRef}
        aria-hidden="true"
        className={`pointer-events-none absolute inset-0 overflow-hidden ${roundedClass} ${className}`}
      >
        {armed && (
          <div
            className="w-full h-full"
            style={{
              opacity: revealed ? 1 : 0,
              transition: 'opacity 150ms var(--ease-out)',
            }}
          >
            {asset.mediaKind === 'video' ? (
              <video
                ref={videoRef}
                src={src}
                muted
                loop
                playsInline
                autoPlay
                preload="auto"
                disablePictureInPicture
                onLoadedData={handleVideoReady}
                onCanPlay={handleVideoReady}
                onError={handleMediaError}
                className={`w-full h-full block ${fitClass}`}
              />
            ) : (
              <img
                src={src}
                alt=""
                decoding="async"
                draggable={false}
                onLoad={handleImageReady}
                onError={handleMediaError}
                className={`w-full h-full block ${fitClass}`}
              />
            )}

            {revealed && asset.mediaKind === 'video' && showMutedBadge && fitsBadge && (
              <span
                className={`absolute ${badgePosClass} z-20 h-5 w-5 rounded-[10px] bg-black/56 backdrop-blur-xs text-white flex items-center justify-center shadow-xs`}
              >
                <VolumeX size={12} strokeWidth={2.2} />
              </span>
            )}
          </div>
        )}
      </div>
    );
  },
);

HoverMediaPreview.displayName = 'HoverMediaPreview';

export { stopAllHoverPreviews as stopActiveHoverPreview };
