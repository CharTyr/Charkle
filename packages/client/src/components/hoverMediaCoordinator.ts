import type { AssetRecord } from '@charkle/shared';

/**
 * Module-level single-active-preview coordinator (0% idle CPU, zero React re-renders).
 * Mirrors native HoverMediaPreview.swift: at most ONE muted hover video/GIF preview
 * plays across the entire application, and scroll/click/drag/blur stops it immediately.
 */

let activeToken: symbol | null = null;
let activeStop: (() => void) | null = null;
let liveScrollingUntil = 0;
let listenersBound = false;

const uncachedMissTimestamps = new Map<string, number>();
const UNCACHED_MISS_TTL_MS = 30_000;

export function supportsHoverPlayback(asset: AssetRecord): boolean {
  if (asset.mediaKind !== 'video' && asset.mediaKind !== 'animatedImage') {
    return false;
  }
  if (asset.richMetadata?.socialPost || asset.richMetadata?.githubRepo) {
    return false;
  }
  return true;
}

export function isFineHoverPointer(): boolean {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
    return false;
  }
  return window.matchMedia('(hover: hover) and (pointer: fine)').matches;
}

export function prefersReducedMotion(): boolean {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
    return false;
  }
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

export function isLiveScrolling(): boolean {
  if (typeof performance === 'undefined') return false;
  return performance.now() < liveScrollingUntil;
}

export function markUncachedHoverMiss(cacheKey: string): void {
  uncachedMissTimestamps.set(cacheKey, Date.now());
  if (uncachedMissTimestamps.size > 256) {
    const oldest = uncachedMissTimestamps.keys().next().value;
    if (oldest !== undefined) uncachedMissTimestamps.delete(oldest);
  }
}

export function hasRecentUncachedHoverMiss(cacheKey: string): boolean {
  const ts = uncachedMissTimestamps.get(cacheKey);
  if (ts === undefined) return false;
  if (Date.now() - ts > UNCACHED_MISS_TTL_MS) {
    uncachedMissTimestamps.delete(cacheKey);
    return false;
  }
  return true;
}

function bindGlobalStopListeners(): void {
  if (listenersBound || typeof window === 'undefined') return;
  listenersBound = true;

  const stop = () => {
    stopAllHoverPreviews();
  };

  window.addEventListener('blur', stop);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible') {
      stopAllHoverPreviews();
    }
  });
  window.addEventListener('pointerdown', stop, { capture: true, passive: true });
  window.addEventListener('dragstart', stop, { capture: true, passive: true });
}

export function claimHoverPreview(token: symbol, stopFn: () => void): boolean {
  bindGlobalStopListeners();

  if (typeof document !== 'undefined' && document.visibilityState !== 'visible') {
    return false;
  }
  if (isLiveScrolling()) {
    return false;
  }

  if (activeToken && activeToken !== token) {
    const prevStop = activeStop;
    activeToken = null;
    activeStop = null;
    prevStop?.();
  }

  activeToken = token;
  activeStop = stopFn;
  return true;
}

export function releaseHoverPreview(token: symbol): void {
  if (activeToken === token) {
    activeToken = null;
    activeStop = null;
  }
}

export function stopAllHoverPreviews(): void {
  const stop = activeStop;
  activeToken = null;
  activeStop = null;
  stop?.();
}

export function notifyLiveScrolling(cooldownMs = 160): void {
  if (typeof performance !== 'undefined') {
    liveScrollingUntil = performance.now() + cooldownMs;
  }
  stopAllHoverPreviews();
}
