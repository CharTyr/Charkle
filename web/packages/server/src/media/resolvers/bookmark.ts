import {
  downloadBoundedBuffer,
  downloadBoundedBufferWithFinalURL,
  extractOpenGraphFromHtml,
} from './social.js';

const MAX_BOOKMARK_HTML_BYTES = 512 * 1024;
const MAX_OG_IMAGE_BYTES = 12 * 1024 * 1024;

export interface ResolvedWebBookmark {
  title: string | null;
  description: string | null;
  imageURL: string | null;
  posterBuffer: Buffer | null;
}

export function isWebURL(rawUrl: string): boolean {
  try {
    const u = new URL(rawUrl.trim());
    return (
      (u.protocol === 'http:' || u.protocol === 'https:') &&
      Boolean(u.hostname) &&
      !u.username &&
      !u.password
    );
  } catch {
    return false;
  }
}

export async function resolveWebBookmark(rawUrl: string): Promise<ResolvedWebBookmark> {
  if (!isWebURL(rawUrl)) {
    return { title: null, description: null, imageURL: null, posterBuffer: null };
  }
  const page = await downloadBoundedBufferWithFinalURL(rawUrl, MAX_BOOKMARK_HTML_BYTES, 10_000);
  if (!page) {
    return { title: null, description: null, imageURL: null, posterBuffer: null };
  }
  const baseURL = page.finalURL && isWebURL(page.finalURL) ? page.finalURL : rawUrl;
  const og = extractOpenGraphFromHtml(page.buffer.toString('utf8'));
  let resolvedImageURL: string | null = null;
  if (og.image) {
    try {
      const candidate = new URL(og.image, baseURL).toString();
      resolvedImageURL = isWebURL(candidate) ? candidate : null;
    } catch {
      resolvedImageURL = null;
    }
  }
  const posterBuffer = resolvedImageURL
    ? await downloadBoundedBuffer(resolvedImageURL, MAX_OG_IMAGE_BYTES, 10_000)
    : null;
  return {
    title: og.title ?? null,
    description: og.description ?? null,
    imageURL: resolvedImageURL,
    posterBuffer,
  };
}
