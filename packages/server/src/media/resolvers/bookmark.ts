import { downloadBoundedBuffer, extractOpenGraphFromHtml } from './social.js';

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
    return u.protocol === 'http:' || u.protocol === 'https:';
  } catch {
    return false;
  }
}

export async function resolveWebBookmark(rawUrl: string): Promise<ResolvedWebBookmark> {
  if (!isWebURL(rawUrl)) {
    return { title: null, description: null, imageURL: null, posterBuffer: null };
  }
  const htmlBuf = await downloadBoundedBuffer(rawUrl, MAX_BOOKMARK_HTML_BYTES, 10_000);
  if (!htmlBuf) {
    return { title: null, description: null, imageURL: null, posterBuffer: null };
  }
  const og = extractOpenGraphFromHtml(htmlBuf.toString('utf8'));
  let resolvedImageURL: string | null = null;
  if (og.image) {
    try {
      resolvedImageURL = new URL(og.image, rawUrl).toString();
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
