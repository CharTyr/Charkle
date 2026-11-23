import {
  socialPlatformDisplayName,
  type SocialMediaAttachment,
  type SocialPlatform,
  type SocialPostMetadata,
} from '@charkle/shared';

const X_HOSTS = new Set([
  'x.com',
  'twitter.com',
  'mobile.x.com',
  'mobile.twitter.com',
  'www.x.com',
  'www.twitter.com',
  'fxtwitter.com',
  'www.fxtwitter.com',
  'vxtwitter.com',
  'www.vxtwitter.com',
  'fixupx.com',
  'www.fixupx.com',
  'fixvx.com',
  'www.fixvx.com',
]);

const BSKY_HOSTS = new Set(['bsky.app', 'www.bsky.app']);
const THREADS_HOSTS = new Set([
  'threads.net',
  'www.threads.net',
  'threads.com',
  'www.threads.com',
]);

export const MAX_SOCIAL_PHOTO_BYTES = 35 * 1024 * 1024;
export const MAX_SOCIAL_VIDEO_BYTES = 160 * 1024 * 1024;
const MAX_HTML_BYTES = 512 * 1024;

export interface ParsedSocialPostURL {
  platform: SocialPlatform;
  handle: string;
  postID: string;
  canonicalURL: string;
}

export function parseSocialPostURL(rawUrl: string): ParsedSocialPostURL | null {
  let u: URL;
  try {
    u = new URL(rawUrl.trim());
  } catch {
    return null;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  const host = u.hostname.toLowerCase();
  const parts = u.pathname.split('/').filter(Boolean);

  // X / Twitter
  if (X_HOSTS.has(host)) {
    if (
      parts.length >= 4 &&
      parts[0].toLowerCase() === 'i' &&
      parts[1].toLowerCase() === 'web' &&
      parts[2].toLowerCase() === 'status' &&
      /^\d{1,24}$/.test(parts[3])
    ) {
      return {
        platform: 'x',
        handle: 'i',
        postID: parts[3],
        canonicalURL: `https://x.com/i/status/${parts[3]}`,
      };
    }
    if (
      parts.length >= 3 &&
      (parts[1].toLowerCase() === 'status' || parts[1].toLowerCase() === 'statuses') &&
      /^\d{1,24}$/.test(parts[2])
    ) {
      const handle = parts[0].replace(/^@/, '');
      return {
        platform: 'x',
        handle,
        postID: parts[2],
        canonicalURL: `https://x.com/${handle}/status/${parts[2]}`,
      };
    }
    return null;
  }

  // Bluesky
  if (BSKY_HOSTS.has(host)) {
    if (parts.length >= 4 && parts[0] === 'profile' && parts[2] === 'post') {
      const handle = parts[1].replace(/^@/, '');
      const rkey = parts[3];
      return {
        platform: 'bluesky',
        handle,
        postID: rkey,
        canonicalURL: `https://bsky.app/profile/${handle}/post/${rkey}`,
      };
    }
    return null;
  }

  // Threads
  if (THREADS_HOSTS.has(host)) {
    if (parts.length >= 3 && parts[0].startsWith('@') && parts[1] === 'post') {
      const handle = parts[0].slice(1);
      const shortcode = parts[2];
      return {
        platform: 'threads',
        handle,
        postID: shortcode,
        canonicalURL: `https://www.threads.net/@${handle}/post/${shortcode}`,
      };
    }
    if (parts.length >= 2 && parts[0] === 't') {
      const shortcode = parts[1];
      return {
        platform: 'threads',
        handle: 'threads',
        postID: shortcode,
        canonicalURL: `https://www.threads.net/t/${shortcode}`,
      };
    }
    return null;
  }

  return null;
}

export function upgradeTwimgPhotoURL(urlStr: string): string {
  try {
    const u = new URL(urlStr);
    if (u.hostname.toLowerCase() === 'pbs.twimg.com') {
      u.searchParams.set('name', 'orig');
      return u.toString();
    }
  } catch {
    // keep raw
  }
  return urlStr;
}

export interface ResolvedSocialPost {
  metadata: SocialPostMetadata;
  title: string;
  markdownArchive: string;
  coverImageBuffer: Buffer | null;
  primaryVideoBuffer: Buffer | null;
}

export async function downloadBoundedBuffer(
  urlStr: string,
  maxBytes: number,
  timeoutMs = 15_000,
): Promise<Buffer | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(urlStr, {
      signal: controller.signal,
      headers: {
        'User-Agent': 'CharkleWeb/1.0 (+https://charkle.app)',
      },
    });
    if (!res.ok) return null;
    const contentLength = Number(res.headers.get('content-length') ?? '0');
    if (contentLength > maxBytes) return null;

    const reader = res.body?.getReader();
    if (!reader) {
      const arr = Buffer.from(await res.arrayBuffer());
      return arr.length <= maxBytes ? arr : null;
    }
    const chunks: Buffer[] = [];
    let total = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => undefined);
        return null;
      }
      chunks.push(Buffer.from(value));
    }
    return Buffer.concat(chunks, total);
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function fetchJsonSafe(urlStr: string, timeoutMs = 10_000): Promise<Record<string, unknown> | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(urlStr, {
      signal: controller.signal,
      headers: {
        Accept: 'application/json',
        'User-Agent': 'CharkleWeb/1.0',
      },
    });
    if (!res.ok) return null;
    const json = (await res.json()) as unknown;
    return json && typeof json === 'object' ? (json as Record<string, unknown>) : null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export function extractOpenGraphFromHtml(html: string): {
  title?: string;
  description?: string;
  image?: string;
} {
  const readMeta = (prop: string): string | undefined => {
    const re1 = new RegExp(
      `<meta[^>]+(?:property|name)=["']${prop}["'][^>]+content=["']([^"']+)["']`,
      'i',
    );
    const re2 = new RegExp(
      `<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']${prop}["']`,
      'i',
    );
    const m = re1.exec(html) ?? re2.exec(html);
    return m ? decodeHtmlEntities(m[1].trim()) : undefined;
  };
  const titleMatch = /<title[^>]*>([^<]+)<\/title>/i.exec(html);
  return {
    title: readMeta('og:title') ?? readMeta('twitter:title') ?? (titleMatch ? decodeHtmlEntities(titleMatch[1].trim()) : undefined),
    description: readMeta('og:description') ?? readMeta('twitter:description') ?? readMeta('description'),
    image: readMeta('og:image') ?? readMeta('twitter:image'),
  };
}

function decodeHtmlEntities(input: string): string {
  return input
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#x27;/g, "'");
}

async function resolveXPost(parsed: ParsedSocialPostURL): Promise<SocialPostMetadata> {
  // 1. Primary: fxtwitter
  const fx = await fetchJsonSafe(`https://api.fxtwitter.com/${parsed.handle}/status/${parsed.postID}`);
  const tweet = fx?.tweet as Record<string, unknown> | undefined;
  if (tweet && typeof tweet === 'object') {
    const author = (tweet.author ?? {}) as Record<string, unknown>;
    const rawText = (tweet.raw_text ?? {}) as Record<string, unknown>;
    const article = (tweet.article ?? {}) as Record<string, unknown>;
    const quote = (tweet.quote ?? null) as Record<string, unknown> | null;
    const media = (tweet.media ?? {}) as Record<string, unknown>;

    const bodyText = String(rawText.text ?? tweet.text ?? article.preview_text ?? '');
    const authorName = String(author.name ?? parsed.handle);
    const authorHandle = String(author.screen_name ?? parsed.handle);
    const attachments: SocialMediaAttachment[] = [];

    const pushItem = (rawItem: Record<string, unknown>): void => {
      const type = String(rawItem.type ?? 'photo').toLowerCase();
      const urlRaw = String(rawItem.url ?? '');
      if (!urlRaw) return;
      const kind: SocialMediaAttachment['kind'] =
        type === 'video' ? 'video' : type === 'gif' ? 'gif' : 'photo';
      const url = kind === 'photo' ? upgradeTwimgPhotoURL(urlRaw) : urlRaw;
      const thumb = typeof rawItem.thumbnail_url === 'string' ? rawItem.thumbnail_url : null;
      attachments.push({ id: `${kind}:${url}`, kind, url, thumbnailURL: thumb });
    };

    if (Array.isArray(media.all) && media.all.length > 0) {
      for (const item of media.all) {
        if (item && typeof item === 'object') pushItem(item as Record<string, unknown>);
      }
    } else {
      if (Array.isArray(media.photos)) {
        for (const p of media.photos) {
          if (p && typeof p === 'object') pushItem({ ...(p as Record<string, unknown>), type: 'photo' });
        }
      }
      if (Array.isArray(media.videos)) {
        for (const v of media.videos) {
          if (v && typeof v === 'object') pushItem({ ...(v as Record<string, unknown>), type: 'video' });
        }
      }
      if (attachments.length === 0) {
        const coverInfo = (article.cover_media as Record<string, unknown> | undefined)?.media_info as
          | Record<string, unknown>
          | undefined;
        if (typeof coverInfo?.original_img_url === 'string') {
          const url = upgradeTwimgPhotoURL(coverInfo.original_img_url);
          attachments.push({ id: `photo:${url}`, kind: 'photo', url, thumbnailURL: url });
        }
      }
      if (attachments.length === 0 && quote?.media && typeof quote.media === 'object') {
        const qm = quote.media as Record<string, unknown>;
        if (Array.isArray(qm.all)) {
          for (const item of qm.all) {
            if (item && typeof item === 'object') pushItem(item as Record<string, unknown>);
          }
        }
      }
    }

    const firstVideo = attachments.find((a) => a.kind === 'video' || a.kind === 'gif');
    const quoteAuthor = quote?.author as Record<string, unknown> | undefined;

    return {
      platform: 'x',
      authorName,
      authorHandle,
      authorAvatarURL: typeof author.avatar_url === 'string' ? author.avatar_url : null,
      publishedAtText: typeof tweet.created_at === 'string' ? tweet.created_at : null,
      bodyText,
      quotedAuthor: quoteAuthor ? String(quoteAuthor.name ?? quoteAuthor.screen_name ?? '') || null : null,
      quotedText: typeof quote?.text === 'string' ? quote.text : null,
      articleTitle: typeof article.title === 'string' ? article.title : null,
      mediaURLs: attachments.map((a) => a.url),
      mediaThumbnailURLs: attachments.map((a) => a.thumbnailURL ?? a.url),
      attachments,
      hasVideo: Boolean(firstVideo),
      videoURL: firstVideo?.url ?? null,
      replyCount: typeof tweet.replies === 'number' ? tweet.replies : null,
      repostCount: typeof tweet.retweets === 'number' ? tweet.retweets : null,
      likeCount: typeof tweet.likes === 'number' ? tweet.likes : null,
      viewCount: typeof tweet.views === 'number' ? tweet.views : null,
      originalURL: parsed.canonicalURL,
      mediaFetchFailed: false,
    };
  }

  // 2. Fallback: vxtwitter
  const vx = await fetchJsonSafe(`https://api.vxtwitter.com/${parsed.handle}/status/${parsed.postID}`);
  if (vx) {
    const attachments: SocialMediaAttachment[] = [];
    if (Array.isArray(vx.media_extended)) {
      for (const m of vx.media_extended) {
        if (!m || typeof m !== 'object') continue;
        const rec = m as Record<string, unknown>;
        const rawUrl = String(rec.url ?? '');
        if (!rawUrl) continue;
        const type = String(rec.type ?? 'image').toLowerCase();
        const kind: SocialMediaAttachment['kind'] =
          type === 'video' ? 'video' : type === 'gif' ? 'gif' : 'photo';
        const url = kind === 'photo' ? upgradeTwimgPhotoURL(rawUrl) : rawUrl;
        const thumb = typeof rec.thumbnail_url === 'string' ? rec.thumbnail_url : null;
        attachments.push({ id: `${kind}:${url}`, kind, url, thumbnailURL: thumb });
      }
    } else if (Array.isArray(vx.mediaURLs)) {
      for (const rawUrl of vx.mediaURLs) {
        if (typeof rawUrl !== 'string') continue;
        const isVid = rawUrl.toLowerCase().includes('.mp4');
        const kind: SocialMediaAttachment['kind'] = isVid ? 'video' : 'photo';
        const url = kind === 'photo' ? upgradeTwimgPhotoURL(rawUrl) : rawUrl;
        attachments.push({ id: `${kind}:${url}`, kind, url, thumbnailURL: null });
      }
    }
    const firstVideo = attachments.find((a) => a.kind === 'video' || a.kind === 'gif');
    return {
      platform: 'x',
      authorName: String(vx.user_name ?? parsed.handle),
      authorHandle: String(vx.user_screen_name ?? parsed.handle),
      authorAvatarURL: typeof vx.user_profile_image_url === 'string' ? vx.user_profile_image_url : null,
      publishedAtText: typeof vx.date === 'string' ? vx.date : null,
      bodyText: String(vx.text ?? ''),
      quotedAuthor: null,
      quotedText: null,
      articleTitle: null,
      mediaURLs: attachments.map((a) => a.url),
      mediaThumbnailURLs: attachments.map((a) => a.thumbnailURL ?? a.url),
      attachments,
      hasVideo: Boolean(firstVideo),
      videoURL: firstVideo?.url ?? null,
      replyCount: typeof vx.replies === 'number' ? vx.replies : null,
      repostCount: typeof vx.retweets === 'number' ? vx.retweets : null,
      likeCount: typeof vx.likes === 'number' ? vx.likes : null,
      viewCount: null,
      originalURL: parsed.canonicalURL,
      mediaFetchFailed: false,
    };
  }

  return {
    platform: 'x',
    authorName: parsed.handle,
    authorHandle: parsed.handle,
    bodyText: '',
    mediaURLs: [],
    mediaThumbnailURLs: [],
    attachments: [],
    hasVideo: false,
    originalURL: parsed.canonicalURL,
    mediaFetchFailed: true,
  };
}

async function resolveBlueskyPost(parsed: ParsedSocialPostURL): Promise<SocialPostMetadata> {
  let did = parsed.handle;
  if (!did.startsWith('did:')) {
    const resolved = await fetchJsonSafe(
      `https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?handle=${encodeURIComponent(parsed.handle)}`,
    );
    if (typeof resolved?.did === 'string') did = resolved.did;
  }

  if (did.startsWith('did:')) {
    const uri = `at://${did}/app.bsky.feed.post/${parsed.postID}`;
    const thread = await fetchJsonSafe(
      `https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?uri=${encodeURIComponent(uri)}&depth=0`,
    );
    const post = (thread?.thread as Record<string, unknown> | undefined)?.post as
      | Record<string, unknown>
      | undefined;
    if (post) {
      const author = (post.author ?? {}) as Record<string, unknown>;
      const record = (post.record ?? {}) as Record<string, unknown>;
      const embed = (post.embed ?? {}) as Record<string, unknown>;
      const attachments: SocialMediaAttachment[] = [];

      const imgs =
        (Array.isArray(embed.images) ? embed.images : null) ??
        (Array.isArray((embed.media as Record<string, unknown> | undefined)?.images)
          ? ((embed.media as Record<string, unknown>).images as unknown[])
          : []);
      for (const img of imgs) {
        if (!img || typeof img !== 'object') continue;
        const rec = img as Record<string, unknown>;
        const full = String(rec.fullsize ?? rec.thumb ?? '');
        if (!full) continue;
        attachments.push({
          id: `photo:${full}`,
          kind: 'photo',
          url: full,
          thumbnailURL: typeof rec.thumb === 'string' ? rec.thumb : full,
        });
      }
      if (typeof embed.playlist === 'string') {
        attachments.push({
          id: `video:${embed.playlist}`,
          kind: 'video',
          url: embed.playlist,
          thumbnailURL: typeof embed.thumbnail === 'string' ? embed.thumbnail : null,
        });
      }
      const firstVideo = attachments.find((a) => a.kind === 'video');
      return {
        platform: 'bluesky',
        authorName: String(author.displayName ?? author.handle ?? parsed.handle),
        authorHandle: String(author.handle ?? parsed.handle),
        authorAvatarURL: typeof author.avatar === 'string' ? author.avatar : null,
        publishedAtText: typeof record.createdAt === 'string' ? record.createdAt : null,
        bodyText: String(record.text ?? ''),
        mediaURLs: attachments.map((a) => a.url),
        mediaThumbnailURLs: attachments.map((a) => a.thumbnailURL ?? a.url),
        attachments,
        hasVideo: Boolean(firstVideo),
        videoURL: firstVideo?.url ?? null,
        replyCount: typeof post.replyCount === 'number' ? post.replyCount : null,
        repostCount: typeof post.repostCount === 'number' ? post.repostCount : null,
        likeCount: typeof post.likeCount === 'number' ? post.likeCount : null,
        viewCount: null,
        originalURL: parsed.canonicalURL,
        mediaFetchFailed: false,
      };
    }
  }

  // Fallback to OG HTML
  return resolveSocialOpenGraphFallback(parsed);
}

async function resolveSocialOpenGraphFallback(parsed: ParsedSocialPostURL): Promise<SocialPostMetadata> {
  const htmlBuf = await downloadBoundedBuffer(parsed.canonicalURL, MAX_HTML_BYTES, 10_000);
  if (!htmlBuf) {
    return {
      platform: parsed.platform,
      authorName: parsed.handle,
      authorHandle: parsed.handle,
      bodyText: '',
      mediaURLs: [],
      mediaThumbnailURLs: [],
      attachments: [],
      hasVideo: false,
      originalURL: parsed.canonicalURL,
      mediaFetchFailed: true,
    };
  }
  const og = extractOpenGraphFromHtml(htmlBuf.toString('utf8'));
  const attachments: SocialMediaAttachment[] = [];
  if (og.image) {
    attachments.push({
      id: `photo:${og.image}`,
      kind: 'photo',
      url: og.image,
      thumbnailURL: og.image,
    });
  }
  return {
    platform: parsed.platform,
    authorName: og.title?.split('(')[0].trim() || parsed.handle,
    authorHandle: parsed.handle,
    bodyText: og.description ?? '',
    mediaURLs: attachments.map((a) => a.url),
    mediaThumbnailURLs: attachments.map((a) => a.thumbnailURL ?? a.url),
    attachments,
    hasVideo: false,
    originalURL: parsed.canonicalURL,
    mediaFetchFailed: false,
  };
}

export async function resolveSocialPost(rawUrl: string): Promise<ResolvedSocialPost | null> {
  const parsed = parseSocialPostURL(rawUrl);
  if (!parsed) return null;

  let metadata: SocialPostMetadata;
  switch (parsed.platform) {
    case 'x':
      metadata = await resolveXPost(parsed);
      break;
    case 'bluesky':
      metadata = await resolveBlueskyPost(parsed);
      break;
    case 'threads':
      metadata = await resolveSocialOpenGraphFallback(parsed);
      break;
  }

  // Download cover thumbnail image for poster card & optional primary MP4 video for offline caching
  let coverImageBuffer: Buffer | null = null;
  let primaryVideoBuffer: Buffer | null = null;

  const firstAtt = metadata.attachments[0];
  const coverUrl = firstAtt?.thumbnailURL ?? (firstAtt?.kind === 'photo' ? firstAtt.url : null);
  if (coverUrl) {
    coverImageBuffer = await downloadBoundedBuffer(coverUrl, MAX_SOCIAL_PHOTO_BYTES, 12_000);
  }
  if (metadata.hasVideo && metadata.videoURL && !metadata.videoURL.toLowerCase().includes('.m3u8')) {
    primaryVideoBuffer = await downloadBoundedBuffer(metadata.videoURL, MAX_SOCIAL_VIDEO_BYTES, 20_000);
    if (!primaryVideoBuffer && !coverImageBuffer) {
      metadata.mediaFetchFailed = true;
    }
  } else if (firstAtt && !coverImageBuffer) {
    metadata.mediaFetchFailed = true;
  }

  const platformLabel = socialPlatformDisplayName(metadata.platform);
  const snippet = (metadata.articleTitle || metadata.bodyText || '').replace(/\s+/g, ' ').trim();
  const title = snippet
    ? `${metadata.authorName}: ${snippet.slice(0, 56)}${snippet.length > 56 ? '…' : ''}`
    : `${metadata.authorName} (@${metadata.authorHandle}) · ${platformLabel}`;

  const mdLines = [
    `# ${metadata.authorName} (@${metadata.authorHandle}) · ${platformLabel}`,
    '',
    metadata.bodyText || '（暂未获取到正文内容）',
  ];
  if (metadata.quotedText) {
    mdLines.push('', `> ${metadata.quotedAuthor ? `**${metadata.quotedAuthor}**: ` : ''}${metadata.quotedText}`);
  }
  mdLines.push('', `原帖链接：${metadata.originalURL}`);

  return {
    metadata,
    title,
    markdownArchive: mdLines.join('\n'),
    coverImageBuffer,
    primaryVideoBuffer,
  };
}
