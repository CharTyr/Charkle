import DOMPurify from 'dompurify';
import { marked } from 'marked';
import { getTransport } from '../api/transport';

const BLOCKED_LOCAL_HOST_SUFFIXES = ['.localhost', '.local', '.localdomain', '.internal'];
const BLOCKED_LOCAL_HOSTS = new Set([
  'localhost',
  '127.0.0.1',
  '0.0.0.0',
  '::1',
  '[::1]',
  'charkle-media.localhost',
  'ipc.localhost',
  'tauri.localhost',
]);

const ALLOWED_VIDEO_EMBED_HOSTS = new Set([
  'www.youtube.com',
  'www.youtube-nocookie.com',
  'player.bilibili.com',
  'player.vimeo.com',
  'geo.dailymotion.com',
  'www.dailymotion.com',
]);

const STRICT_RELEASE_NOTES_TAGS = [
  'h1',
  'h2',
  'h3',
  'h4',
  'p',
  'ul',
  'ol',
  'li',
  'strong',
  'em',
  'code',
  'pre',
  'blockquote',
  'hr',
  'br',
  'a',
];

function isBlockedInternalHostname(hostname: string): boolean {
  const lower = hostname.trim().toLowerCase().replace(/\.+$/, '');
  if (!lower) return true;
  if (BLOCKED_LOCAL_HOSTS.has(lower)) return true;
  return BLOCKED_LOCAL_HOST_SUFFIXES.some((suffix) => lower.endsWith(suffix));
}

export interface SanitizeMarkdownOptions {
  allowImages?: boolean;
  breaks?: boolean;
  strictReleaseNotes?: boolean;
  baseLinkUrl?: string;
}

/**
 * Parses untrusted Markdown and sanitizes the resulting HTML through a hardened DOMPurify profile:
 * - Blocks inline `style`, `data-*`, `aria-*`, `<svg>`, `<math>`, `<form>`, media embeds, and event handlers
 * - Enforces `http:`/`https:`/`mailto:`/`#` URI allowlist and adds `rel="noopener noreferrer"` on anchors
 * - Strips internal/loopback/custom-protocol image probes (`charkle-media.localhost`, `localhost`, etc.)
 */
export function sanitizeMarkdownHtml(
  markdown: string,
  options: SanitizeMarkdownOptions = {},
): string {
  const source = markdown.trim();
  if (!source) return '';

  const { allowImages = true, breaks = false, strictReleaseNotes = false, baseLinkUrl } = options;

  let rawHtml: string;
  if (baseLinkUrl) {
    const renderer = new marked.Renderer();
    const originalLink = renderer.link.bind(renderer);
    renderer.link = (token) => {
      const href = token.href?.trim() ?? '';
      if (
        href &&
        !href.startsWith('#') &&
        !/^[a-z][a-z0-9+.-]*:/i.test(href)
      ) {
        try {
          const resolved = new URL(href.replace(/^\/+/, ''), baseLinkUrl).toString();
          return originalLink({ ...token, href: resolved });
        } catch {
          // Keep original token; DOMPurify will strip invalid schemes
        }
      }
      return originalLink(token);
    };
    rawHtml = marked.parse(source, { async: false, gfm: true, breaks, renderer }) as string;
  } else {
    rawHtml = marked.parse(source, { async: false, gfm: true, breaks }) as string;
  }

  const hook = (node: Element) => {
    const tag = node.tagName?.toUpperCase();
    if (tag === 'A') {
      const href = node.getAttribute('href')?.trim() ?? '';
      if (!/^(?:https?:\/\/|mailto:|#)/i.test(href)) {
        node.removeAttribute('href');
      } else {
        node.setAttribute('rel', 'noopener noreferrer');
      }
      node.removeAttribute('target');
    } else if (tag === 'IMG') {
      if (!allowImages || strictReleaseNotes) {
        node.remove();
        return;
      }
      const src = node.getAttribute('src')?.trim() ?? '';
      try {
        const parsed = new URL(src);
        if (
          (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') ||
          isBlockedInternalHostname(parsed.hostname)
        ) {
          node.remove();
          return;
        }
        node.setAttribute('referrerpolicy', 'no-referrer');
        node.setAttribute('loading', 'lazy');
      } catch {
        node.remove();
      }
    }
  };

  DOMPurify.addHook('afterSanitizeAttributes', hook);
  try {
    return DOMPurify.sanitize(rawHtml, {
      USE_PROFILES: { html: true },
      ALLOW_DATA_ATTR: false,
      ALLOW_ARIA_ATTR: false,
      ALLOWED_URI_REGEXP: /^(?:https?:\/\/|mailto:|#)/i,
      ...(strictReleaseNotes
        ? {
            ALLOWED_TAGS: STRICT_RELEASE_NOTES_TAGS,
            ALLOWED_ATTR: ['href', 'title', 'rel'],
          }
        : {
            FORBID_TAGS: [
              'svg',
              'math',
              'style',
              'script',
              'iframe',
              'object',
              'embed',
              'form',
              'input',
              'textarea',
              'select',
              'button',
              'audio',
              'video',
              'source',
              'meta',
              'link',
              'base',
            ],
            FORBID_ATTR: [
              'style',
              'target',
              'srcset',
              'formaction',
              'xlink:href',
              'onerror',
              'onload',
              'onclick',
              'onmouseover',
            ],
          }),
    });
  } finally {
    DOMPurify.removeHook('afterSanitizeAttributes');
  }
}

/** Validates an external URL strictly to `http:` or `https:` (or optionally `mailto:`). */
export function parseSafeExternalUrl(
  rawUrl: string | null | undefined,
  opts?: { allowMailto?: boolean },
): string | null {
  const trimmed = rawUrl?.trim();
  if (!trimmed) return null;
  try {
    const parsed = new URL(trimmed);
    if (parsed.protocol === 'https:' || parsed.protocol === 'http:') {
      return parsed.toString();
    }
    if (opts?.allowMailto && parsed.protocol === 'mailto:') {
      return parsed.toString();
    }
    return null;
  } catch {
    return null;
  }
}

/** Opens an untrusted external link only after verifying its protocol is `http:`/`https:` (or `mailto:`). */
export async function openSafeExternalUrl(
  rawUrl: string | null | undefined,
  opts?: { allowMailto?: boolean; onError?: (message: string) => void },
): Promise<boolean> {
  const safe = parseSafeExternalUrl(rawUrl, { allowMailto: opts?.allowMailto });
  if (!safe) {
    opts?.onError?.('不支持或无效的外部链接地址');
    return false;
  }
  try {
    await getTransport().openExternalUrl(safe);
    return true;
  } catch {
    opts?.onError?.('无法在默认浏览器中打开链接');
    return false;
  }
}

/** Validates a third-party video iframe embed URL against strict HTTPS + official provider allowlist. */
export function isAllowedVideoEmbedUrl(rawUrl: string | null | undefined): boolean {
  const trimmed = rawUrl?.trim();
  if (!trimmed) return false;
  try {
    const parsed = new URL(trimmed);
    if (parsed.protocol !== 'https:') return false;
    return ALLOWED_VIDEO_EMBED_HOSTS.has(parsed.hostname.toLowerCase());
  } catch {
    return false;
  }
}

/**
 * Copies plain text to the system clipboard and rejects explicitly when the Clipboard API is
 * unavailable or fails, preventing false-positive "已复制" toasts.
 */
export async function copyTextToClipboard(text: string): Promise<void> {
  if (typeof navigator === 'undefined' || !navigator.clipboard?.writeText) {
    throw new Error('当前环境不支持直接写入剪贴板');
  }
  await navigator.clipboard.writeText(text);
}

/**
 * Returns `true` when either Windows "Animation effects = Off" (`data-animations="disabled"`)
 * or CSS `(prefers-reduced-motion: reduce)` is active.
 */
export function isSystemMotionReduced(): boolean {
  if (typeof document !== 'undefined' && document.documentElement.dataset.animations === 'disabled') {
    return true;
  }
  if (typeof window !== 'undefined' && typeof window.matchMedia === 'function') {
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  }
  return false;
}
