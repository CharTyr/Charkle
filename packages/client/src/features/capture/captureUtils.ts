import type { CaptureInput } from '@charkle/shared';

export type DetectedURLKind = 'x' | 'threads' | 'bluesky' | 'github' | 'web';

export interface DetectedURLInfo {
  url: string;
  kind: DetectedURLKind;
  badge: string;
}

const HEX_COLOR_RE = /^#?[0-9a-fA-F]{6}$/;

export function normalizeHexInput(raw: string): string | null {
  const trimmed = raw.trim();
  if (!HEX_COLOR_RE.test(trimmed)) return null;
  return `#${trimmed.replace(/^#/, '').toUpperCase()}`;
}

export function detectURLFromText(raw: string): DetectedURLInfo | null {
  const trimmed = raw.trim();
  if (!trimmed || /\s/.test(trimmed)) return null;
  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return null;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return null;
  }
  const host = parsed.hostname.toLowerCase();
  const path = parsed.pathname;

  if (
    (host === 'x.com' ||
      host === 'www.x.com' ||
      host === 'mobile.x.com' ||
      host === 'twitter.com' ||
      host === 'www.twitter.com' ||
      host === 'mobile.twitter.com' ||
      host === 'fxtwitter.com' ||
      host === 'vxtwitter.com' ||
      host === 'fixupx.com' ||
      host === 'fixvx.com') &&
    /\/status(es)?\/\d{1,24}/i.test(path)
  ) {
    return { url: trimmed, kind: 'x', badge: 'X 推文' };
  }

  if (
    (host === 'threads.net' ||
      host === 'www.threads.net' ||
      host === 'threads.com' ||
      host === 'www.threads.com') &&
    (/^\/@[^/]+\/post\/[^/]+/i.test(path) || /^\/t\/[^/]+/i.test(path))
  ) {
    return { url: trimmed, kind: 'threads', badge: 'Threads 贴文' };
  }

  if (
    (host === 'bsky.app' || host === 'www.bsky.app') &&
    /^\/profile\/[^/]+\/post\/[^/]+/i.test(path)
  ) {
    return { url: trimmed, kind: 'bluesky', badge: 'Bluesky 贴文' };
  }

  if (
    (host === 'github.com' || host === 'www.github.com') &&
    /^\/[^/]+\/[^/]+(\/tree\/[^/]+)?\/?$/i.test(path)
  ) {
    return { url: trimmed, kind: 'github', badge: 'GitHub 仓库' };
  }

  return { url: trimmed, kind: 'web', badge: '网页书签' };
}

export function fileToBase64(file: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error('读取文件失败'));
    reader.onload = () => {
      const result = typeof reader.result === 'string' ? reader.result : '';
      const comma = result.indexOf(',');
      resolve(comma >= 0 ? result.slice(comma + 1) : result);
    };
    reader.readAsDataURL(file);
  });
}

export function textToCaptureInput(rawText: string): CaptureInput | null {
  const trimmed = rawText.trim();
  if (!trimmed) return null;

  const hex = normalizeHexInput(trimmed);
  if (hex) {
    return {
      type: 'colorSwatch',
      hex,
      title: `色卡 ${hex}`,
    };
  }

  const urlInfo = detectURLFromText(trimmed);
  if (urlInfo) {
    return {
      type: 'webURL',
      url: urlInfo.url,
    };
  }

  const firstLine = trimmed.split(/\r?\n/)[0]?.trim() || '灵感笔记';
  return {
    type: 'textSnippet',
    title: firstLine.slice(0, 48),
    text: trimmed,
  };
}

/**
 * Capture a single high-resolution PNG frame via Screen Capture API (`getDisplayMedia`).
 */
export async function captureScreenFrame(): Promise<CaptureInput> {
  if (!navigator.mediaDevices || typeof navigator.mediaDevices.getDisplayMedia !== 'function') {
    throw new Error('当前浏览器不支持屏幕截屏');
  }

  const stream = await navigator.mediaDevices.getDisplayMedia({
    video: { frameRate: { ideal: 1, max: 5 } },
    audio: false,
  });

  try {
    const video = document.createElement('video');
    video.srcObject = stream;
    video.muted = true;
    video.playsInline = true;

    await new Promise<void>((resolve, reject) => {
      video.onloadedmetadata = () => {
        video.play().then(() => resolve()).catch(reject);
      };
      video.onerror = () => reject(new Error('无法读取屏幕视频帧'));
    });

    await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));

    const width = Math.max(1, video.videoWidth);
    const height = Math.max(1, video.videoHeight);
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      throw new Error('Canvas 2D 上下文不可用');
    }
    ctx.drawImage(video, 0, 0, width, height);

    const dataUrl = canvas.toDataURL('image/png');
    const base64Data = dataUrl.slice(dataUrl.indexOf(',') + 1);
    const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);

    return {
      type: 'imageData',
      base64Data,
      suggestedName: `charkle-screen-${stamp}.png`,
    };
  } finally {
    for (const track of stream.getTracks()) {
      track.stop();
    }
  }
}

export function isEditableElement(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  if (target.isContentEditable) return true;
  const tag = target.tagName;
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
}
