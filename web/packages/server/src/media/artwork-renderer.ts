import sharp, { type OverlayOptions } from 'sharp';
import type { GitHubRepoMetadata, LabColor, SocialPostMetadata } from '@charkle/shared';
import {
  buildAudioWaveformSvg,
  buildColorSwatchSvg,
  buildGenericBadgeSvg,
  buildGitHubRepoSvg,
  buildModel3DSvg,
  buildSocialPostSvg,
  buildTextDocumentSvg,
  buildWebBookmarkSvg,
  wrapLines,
} from './artwork-svg.js';

export { wrapLines };

export async function renderSvgToPng(svg: string): Promise<Buffer> {
  return sharp(Buffer.from(svg, 'utf8')).png({ compressionLevel: 6 }).toBuffer();
}

export async function renderColorSwatchCard(color: LabColor, title?: string): Promise<Buffer> {
  return renderSvgToPng(buildColorSwatchSvg(color, title).svg);
}

export async function renderTextDocumentCard(
  title: string,
  badge: string,
  excerpt: string,
): Promise<Buffer> {
  return renderSvgToPng(buildTextDocumentSvg(title, badge, excerpt).svg);
}

export async function renderAudioWaveformCard(
  title: string,
  peaks: readonly number[],
  durationSeconds: number | null,
): Promise<Buffer> {
  return renderSvgToPng(buildAudioWaveformSvg(title, peaks, durationSeconds).svg);
}

export async function renderModel3DCard(title: string, format: string): Promise<Buffer> {
  return renderSvgToPng(buildModel3DSvg(title, format).svg);
}

export async function renderGitHubRepoCard(repo: GitHubRepoMetadata): Promise<Buffer> {
  return renderSvgToPng(buildGitHubRepoSvg(repo).svg);
}

export async function renderSocialPostCard(
  post: SocialPostMetadata,
  coverImageBuffer?: Buffer | null,
  authorAvatarBuffer?: Buffer | null,
): Promise<Buffer> {
  const composites: OverlayOptions[] = [];

  let circularAvatar: Buffer | null = null;
  if (authorAvatarBuffer && authorAvatarBuffer.length > 0) {
    try {
      const fittedAvatar = await sharp(authorAvatarBuffer)
        .rotate()
        .resize(52, 52, { fit: 'cover', position: 'centre' })
        .ensureAlpha()
        .png()
        .toBuffer();
      const avatarMask = Buffer.from(
        `<svg xmlns="http://www.w3.org/2000/svg" width="52" height="52"><circle cx="26" cy="26" r="26" fill="#fff"/></svg>`,
      );
      const avatarRing = Buffer.from(
        `<svg xmlns="http://www.w3.org/2000/svg" width="52" height="52"><circle cx="26" cy="26" r="25.25" fill="none" stroke="rgba(0,0,0,0.08)" stroke-width="1.5"/></svg>`,
      );
      circularAvatar = await sharp(fittedAvatar)
        .composite([
          { input: avatarMask, blend: 'dest-in' },
          { input: avatarRing, blend: 'over' },
        ])
        .png()
        .toBuffer();
    } catch {
      circularAvatar = null;
    }
  }

  const { svg: baseSvg, width } = buildSocialPostSvg(post, {
    hasExternalCover: Boolean(coverImageBuffer),
    hasExternalAvatar: Boolean(circularAvatar),
  });
  const basePng = await renderSvgToPng(baseSvg);

  if (circularAvatar) {
    composites.push({ input: circularAvatar, left: 52, top: 58 });
  }

  if (coverImageBuffer) {
    const mediaTop = 415;
    const mediaH = 420;
    try {
      const fittedCover = await sharp(coverImageBuffer)
        .rotate()
        .resize(696, mediaH, { fit: 'cover', position: 'centre' })
        .png()
        .toBuffer();

      const maskSvg = Buffer.from(
        `<svg xmlns="http://www.w3.org/2000/svg" width="696" height="${mediaH}"><rect width="696" height="${mediaH}" rx="18" fill="#fff"/></svg>`,
      );
      const roundedCover = await sharp(fittedCover)
        .composite([{ input: maskSvg, blend: 'dest-in' }])
        .png()
        .toBuffer();

      composites.push({ input: roundedCover, left: 52, top: mediaTop });
      if (post.hasVideo) {
        const overlaySvg = Buffer.from(
          `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><circle cx="50" cy="50" r="42" fill="rgba(20,21,23,0.74)" stroke="rgba(255,255,255,0.85)" stroke-width="2.5"/><polygon points="40,34 40,66 68,50" fill="#FFFFFF"/></svg>`,
        );
        composites.push({
          input: overlaySvg,
          left: Math.round(width / 2 - 50),
          top: Math.round(mediaTop + mediaH / 2 - 50),
        });
      }
    } catch {
      // keep basePng + avatar if cover decode failed
    }
  }

  if (composites.length === 0) return basePng;
  return sharp(basePng).composite(composites).png().toBuffer();
}

export async function renderWebBookmarkCard(
  title: string,
  domain: string,
  description?: string | null,
): Promise<Buffer> {
  return renderSvgToPng(buildWebBookmarkSvg(title, domain, description).svg);
}

export async function renderGenericBadgeCard(
  title: string,
  ext: string,
  kindLabel: string,
): Promise<Buffer> {
  return renderSvgToPng(buildGenericBadgeSvg(title, ext, kindLabel).svg);
}
