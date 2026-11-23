import {
  isLightHex,
  socialPlatformDisplayName,
  type GitHubRepoMetadata,
  type LabColor,
  type SocialPlatform,
  type SocialPostMetadata,
} from '@charkle/shared';
import { bytesToBase64 } from '../runtime/web-crypto-utils.js';

export interface SvgCardOutput {
  svg: string;
  width: number;
  height: number;
}

export function escapeXml(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function charWeight(ch: string): number {
  return ch.charCodeAt(0) > 255 ? 1.85 : 1;
}

function stringWeight(text: string): number {
  let w = 0;
  for (const ch of text) w += charWeight(ch);
  return w;
}

function tokenizeLineForWrap(para: string): string[] {
  const tokens: string[] = [];
  let buf = '';
  for (const ch of para) {
    if (ch === ' ' || ch === '\t') {
      if (buf) {
        tokens.push(buf);
        buf = '';
      }
      if (tokens.length > 0 && tokens[tokens.length - 1] !== ' ') {
        tokens.push(' ');
      }
    } else if (ch.charCodeAt(0) > 255) {
      if (buf) {
        tokens.push(buf);
        buf = '';
      }
      tokens.push(ch);
    } else {
      buf += ch;
    }
  }
  if (buf) tokens.push(buf);
  return tokens;
}

/**
 * Wraps mixed Latin + CJK text cleanly on whitespace word boundaries for Latin words,
 * falling back to character slicing only for CJK characters or single tokens exceeding line width.
 */
export function wrapLines(text: string, maxCharsPerLine: number, maxLines: number): string[] {
  const clean = text.replace(/\r/g, '').trim();
  if (!clean || maxLines <= 0) return [];
  const paragraphs = clean.split('\n');
  const lines: string[] = [];
  let truncated = false;

  outer: for (let pIdx = 0; pIdx < paragraphs.length; pIdx++) {
    const para = paragraphs[pIdx].trim();
    if (!para) continue;
    const tokens = tokenizeLineForWrap(para);
    let cur = '';
    let curW = 0;

    for (let tIdx = 0; tIdx < tokens.length; tIdx++) {
      const tok = tokens[tIdx];
      if (tok === ' ' && cur.length === 0) continue;

      const tokW = stringWeight(tok);
      if (curW + tokW <= maxCharsPerLine) {
        cur += tok;
        curW += tokW;
        continue;
      }

      if (cur.trim().length > 0) {
        lines.push(cur.trimEnd());
        cur = '';
        curW = 0;
        if (lines.length >= maxLines) {
          truncated = true;
          break outer;
        }
        if (tok === ' ') continue;
        if (tokW <= maxCharsPerLine) {
          cur = tok;
          curW = tokW;
          continue;
        }
      }

      for (const ch of tok) {
        const w = charWeight(ch);
        if (curW + w > maxCharsPerLine && cur.length > 0) {
          lines.push(cur.trimEnd());
          cur = '';
          curW = 0;
          if (lines.length >= maxLines) {
            truncated = true;
            break outer;
          }
        }
        cur += ch;
        curW += w;
      }
    }

    if (cur.trim().length > 0) {
      lines.push(cur.trimEnd());
      if (lines.length >= maxLines) {
        for (let nextP = pIdx + 1; nextP < paragraphs.length; nextP++) {
          if (paragraphs[nextP].trim().length > 0) {
            truncated = true;
            break;
          }
        }
        break outer;
      }
    }
  }

  if (truncated && lines.length > 0) {
    let last = lines[lines.length - 1].replace(/[\s,.;:，。；：]+$/, '');
    if (stringWeight(last) + 1.5 > maxCharsPerLine && last.length > 1) {
      last = last.slice(0, -1).trimEnd();
    }
    lines[lines.length - 1] = `${last}…`;
  }
  return lines;
}

const GITHUB_LANGUAGE_COLORS: Record<string, string> = {
  Swift: '#F05138',
  TypeScript: '#3178C6',
  JavaScript: '#F1E05A',
  Python: '#3572A5',
  Rust: '#DEA584',
  Go: '#00ADD8',
  HTML: '#E34C26',
  CSS: '#563D7C',
};

function socialPlatformAccent(platform: SocialPlatform): string {
  switch (platform) {
    case 'x':
      return '#18181B';
    case 'threads':
      return '#27272A';
    case 'bluesky':
      return '#0284C7';
  }
}

export function buildColorSwatchSvg(color: LabColor, title?: string): SvgCardOutput {
  const light = isLightHex(color.hex);
  const fg = light ? '#1C1D21' : '#F6F6F5';
  const muted = light ? 'rgba(28,29,33,0.58)' : 'rgba(246,246,245,0.68)';
  const label = title && title.toUpperCase() !== color.hex.toUpperCase() ? title : 'COLOR SWATCH';
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="720" height="720" viewBox="0 0 720 720">
    <rect width="720" height="720" fill="${escapeXml(color.hex)}"/>
    <rect x="44" y="560" width="632" height="1" fill="${muted}" opacity="0.35"/>
    <text x="44" y="620" fill="${fg}" font-family="-apple-system, BlinkMacSystemFont, Helvetica Neue, sans-serif" font-size="44" font-weight="700" letter-spacing="1">${escapeXml(color.hex)}</text>
    <text x="44" y="662" fill="${muted}" font-family="-apple-system, BlinkMacSystemFont, Helvetica Neue, sans-serif" font-size="22" font-weight="500">${escapeXml(label.slice(0, 36))}</text>
  </svg>`;
  return { svg, width: 720, height: 720 };
}

export function buildTextDocumentSvg(
  title: string,
  badge: string,
  excerpt: string,
): SvgCardOutput {
  const titleLines = wrapLines(title, 26, 2);
  const bodyLines = wrapLines(excerpt, 38, 12);
  const titleSvg = titleLines
    .map(
      (line, i) =>
        `<text x="56" y="${174 + i * 44}" fill="#1A1B1F" font-family="-apple-system, BlinkMacSystemFont, PingFang SC, Helvetica Neue, sans-serif" font-size="34" font-weight="700">${escapeXml(line)}</text>`,
    )
    .join('');
  const bodyTop = 174 + titleLines.length * 44 + 28;
  const bodySvg = bodyLines
    .map(
      (line, i) =>
        `<text x="56" y="${bodyTop + i * 36}" fill="#4A4E58" font-family="ui-monospace, SFMono-Regular, Menlo, PingFang SC, sans-serif" font-size="21">${escapeXml(line)}</text>`,
    )
    .join('');

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="760" height="900" viewBox="0 0 760 900">
    <rect width="760" height="900" fill="#F8F7F3"/>
    <rect x="32" y="32" width="696" height="836" rx="24" fill="#FFFFFF" stroke="#E5E3DC" stroke-width="2"/>
    <rect x="56" y="68" width="${Math.max(76, badge.length * 16 + 28)}" height="36" rx="10" fill="#EDEDE9"/>
    <text x="70" y="92" fill="#445C94" font-family="-apple-system, BlinkMacSystemFont, Helvetica Neue, sans-serif" font-size="17" font-weight="700">${escapeXml(badge.slice(0, 10))}</text>
    ${titleSvg}
    <rect x="56" y="${bodyTop - 36}" width="648" height="1.5" fill="#EBE9E2"/>
    ${bodySvg}
  </svg>`;
  return { svg, width: 760, height: 900 };
}

export function buildAudioWaveformSvg(
  title: string,
  peaks: readonly number[],
  durationSeconds: number | null,
): SvgCardOutput {
  const bars =
    peaks.length > 0
      ? peaks.slice(0, 48)
      : Array.from({ length: 48 }, (_, i) => 0.25 + 0.65 * Math.abs(Math.sin(i * 0.35)));
  const durLabel =
    durationSeconds !== null && Number.isFinite(durationSeconds)
      ? `${Math.floor(durationSeconds / 60)}:${String(Math.floor(durationSeconds % 60)).padStart(2, '0')}`
      : 'AUDIO';

  const barWidth = 10;
  const gap = 7;
  const startX = 64;
  const midY = 350;
  const maxHalfH = 118;

  const barsSvg = bars
    .map((p, i) => {
      const h = Math.max(14, Math.round(Math.max(0.08, Math.min(1, p)) * maxHalfH * 2));
      const x = startX + i * (barWidth + gap);
      const y = Math.round(midY - h / 2);
      const fill = i < Math.floor(bars.length * 0.38) ? '#8EA8E8' : '#3E4963';
      return `<rect x="${x}" y="${y}" width="${barWidth}" height="${h}" rx="5" fill="${fill}"/>`;
    })
    .join('');

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="930" height="600" viewBox="0 0 930 600">
    <rect width="930" height="600" fill="#15171C"/>
    <rect x="34" y="34" width="862" height="532" rx="28" fill="#1C1F27" stroke="#2D3240" stroke-width="2"/>
    <circle cx="98" cy="112" r="32" fill="#445C94"/>
    <polygon points="90,97 90,127 115,112" fill="#FFFFFF"/>
    <text x="150" y="106" fill="#F2F4F8" font-family="-apple-system, BlinkMacSystemFont, PingFang SC, Helvetica Neue, sans-serif" font-size="28" font-weight="700">${escapeXml(title.slice(0, 34))}</text>
    <text x="150" y="138" fill="#8B93A7" font-family="ui-monospace, SFMono-Regular, Menlo, sans-serif" font-size="18">${escapeXml(durLabel)} · 48-BAR WAVEFORM</text>
    ${barsSvg}
  </svg>`;
  return { svg, width: 930, height: 600 };
}

export function buildModel3DSvg(title: string, format: string): SvgCardOutput {
  const fmt = (format || '3D').toUpperCase().slice(0, 8);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="800" height="800" viewBox="0 0 800 800">
    <defs>
      <radialGradient id="studio" cx="50%" cy="42%" r="60%">
        <stop offset="0%" stop-color="#272C38"/>
        <stop offset="100%" stop-color="#14161B"/>
      </radialGradient>
    </defs>
    <rect width="800" height="800" fill="url(#studio)"/>
    <g stroke="#8EA8E8" stroke-width="2.5" fill="none" opacity="0.88">
      <polygon points="400,150 610,270 610,510 400,630 190,510 190,270" fill="rgba(68,92,148,0.16)"/>
      <polyline points="190,270 400,390 610,270"/>
      <line x1="400" y1="390" x2="400" y2="630"/>
      <polyline points="400,150 400,390" stroke-dasharray="6 8" opacity="0.45"/>
      <polyline points="190,510 400,390 610,510" stroke-dasharray="6 8" opacity="0.45"/>
    </g>
    <rect x="48" y="48" width="${Math.max(82, fmt.length * 16 + 34)}" height="38" rx="10" fill="#232834" stroke="#394358"/>
    <text x="66" y="73" fill="#B4C6F0" font-family="ui-monospace, SFMono-Regular, Menlo, sans-serif" font-size="18" font-weight="700">${escapeXml(fmt)}</text>
    <text x="48" y="732" fill="#F2F4F8" font-family="-apple-system, BlinkMacSystemFont, PingFang SC, Helvetica Neue, sans-serif" font-size="28" font-weight="600">${escapeXml(title.slice(0, 34))}</text>
  </svg>`;
  return { svg, width: 800, height: 800 };
}

export function buildGitHubRepoSvg(repo: GitHubRepoMetadata): SvgCardOutput {
  const langColor = (repo.language && GITHUB_LANGUAGE_COLORS[repo.language]) || '#60A5FA';
  const descLines = wrapLines(repo.description ?? 'GitHub Repository', 44, 3);
  const descSvg = descLines
    .map(
      (line, i) =>
        `<text x="52" y="${236 + i * 36}" fill="#B4BCCB" font-family="-apple-system, BlinkMacSystemFont, PingFang SC, Helvetica Neue, sans-serif" font-size="24">${escapeXml(line)}</text>`,
    )
    .join('');

  const topics = repo.topics.slice(0, 5);
  let chipX = 52;
  const chipsSvg = topics
    .map((topic) => {
      const w = Math.min(180, Math.max(72, topic.length * 11 + 28));
      const el = `<rect x="${chipX}" y="470" width="${w}" height="36" rx="10" fill="#1E232B" stroke="#2D3542"/><text x="${chipX + 14}" y="494" fill="#A6B4CC" font-family="ui-monospace, Menlo, sans-serif" font-size="16">${escapeXml(topic.slice(0, 14))}</text>`;
      chipX += w + 12;
      return chipX < 760 ? el : '';
    })
    .join('');

  const formatNum = (n: number): string => (n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n));
  const stats = [
    `★ ${formatNum(repo.stars)}`,
    `⑂ ${formatNum(repo.forks)}`,
    repo.licenseName ?? '',
  ].filter(Boolean);

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="820" height="620" viewBox="0 0 820 620">
    <rect width="820" height="620" fill="#111317"/>
    <rect x="28" y="28" width="764" height="564" rx="22" fill="#161920" stroke="#252B36" stroke-width="2"/>
    <rect x="52" y="56" width="118" height="36" rx="10" fill="#1E232B"/>
    <text x="72" y="80" fill="#E6ECF5" font-family="-apple-system, BlinkMacSystemFont, Helvetica Neue, sans-serif" font-size="17" font-weight="700">GITHUB</text>
    <text x="52" y="142" fill="#8B95A8" font-family="ui-monospace, Menlo, sans-serif" font-size="22">${escapeXml(repo.owner)}</text>
    <text x="52" y="188" fill="#F6F8FC" font-family="-apple-system, BlinkMacSystemFont, Helvetica Neue, sans-serif" font-size="40" font-weight="700">${escapeXml(repo.repo.slice(0, 28))}</text>
    ${descSvg}
    <g transform="translate(52, 385)">
      ${repo.language ? `<circle cx="9" cy="-6" r="7" fill="${langColor}"/><text x="26" y="0" fill="#DCE3F0" font-family="-apple-system, Helvetica Neue, sans-serif" font-size="20" font-weight="600">${escapeXml(repo.language)}</text>` : ''}
      <text x="${repo.language ? 190 : 0}" y="0" fill="#9AA4B8" font-family="ui-monospace, Menlo, sans-serif" font-size="20">${escapeXml(stats.join('   ·   '))}</text>
    </g>
    ${chipsSvg}
  </svg>`;
  return { svg, width: 820, height: 620 };
}

function sniffInlineImageMime(bytes: Uint8Array): string {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 4 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[8] === 0x57 && bytes[9] === 0x45) {
    return 'image/webp';
  }
  if (bytes.length >= 4 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
    return 'image/gif';
  }
  return 'image/jpeg';
}

export function buildSocialPostSvg(
  post: SocialPostMetadata,
  options: { hasExternalCover?: boolean; inlineCoverBytes?: Uint8Array | null } = {},
): SvgCardOutput {
  const inlineCover = options.inlineCoverBytes && options.inlineCoverBytes.byteLength > 0
    ? options.inlineCoverBytes
    : null;
  const hasMedia =
    Boolean(options.hasExternalCover) ||
    Boolean(inlineCover) ||
    post.mediaURLs.length > 0 ||
    post.attachments.length > 0;
  const width = 800;
  const height = hasMedia ? 920 : 620;
  const badgeColor = socialPlatformAccent(post.platform);
  const badgeLabel = socialPlatformDisplayName(post.platform);
  const bodyLines = wrapLines(
    post.bodyText || post.articleTitle || post.originalURL,
    38,
    hasMedia ? 5 : 9,
  );

  const bodySvg = bodyLines
    .map(
      (line, i) =>
        `<text x="52" y="${198 + i * 38}" fill="#1E2024" font-family="-apple-system, BlinkMacSystemFont, PingFang SC, Helvetica Neue, sans-serif" font-size="25">${escapeXml(line)}</text>`,
    )
    .join('');

  const mediaTop = 415;
  const mediaH = 420;
  const playOverlay = post.hasVideo
    ? `<circle cx="400" cy="${mediaTop + mediaH / 2}" r="42" fill="rgba(20,21,23,0.72)" stroke="rgba(255,255,255,0.8)" stroke-width="2.5"/><polygon points="390,${mediaTop + mediaH / 2 - 16} 390,${mediaTop + mediaH / 2 + 16} 418,${mediaTop + mediaH / 2}" fill="#FFFFFF"/>`
    : '';

  let mediaBlock = '';
  if (inlineCover) {
    const mime = sniffInlineImageMime(inlineCover);
    const dataUri = `data:${mime};base64,${bytesToBase64(inlineCover)}`;
    mediaBlock = `<defs><clipPath id="socialCoverClip"><rect x="52" y="${mediaTop}" width="696" height="${mediaH}" rx="18"/></clipPath></defs>
      <image href="${dataUri}" x="52" y="${mediaTop}" width="696" height="${mediaH}" preserveAspectRatio="xMidYMid slice" clip-path="url(#socialCoverClip)"/>
      ${playOverlay}`;
  } else if (hasMedia && !options.hasExternalCover) {
    mediaBlock = `<rect x="52" y="${mediaTop}" width="696" height="${mediaH}" rx="18" fill="#EAE9E4"/>${playOverlay}`;
  }

  const handleLine = `@${post.authorHandle.replace(/^@/, '').slice(0, 28)} · ${badgeLabel}`;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
    <rect width="${width}" height="${height}" fill="#F6F6F4"/>
    <rect x="26" y="26" width="${width - 52}" height="${height - 52}" rx="24" fill="#FFFFFF" stroke="#E4E3DD" stroke-width="2"/>
    <text x="52" y="88" fill="#18191D" font-family="-apple-system, BlinkMacSystemFont, PingFang SC, Helvetica Neue, sans-serif" font-size="28" font-weight="700">${escapeXml(post.authorName.slice(0, 28))}</text>
    <circle cx="58" cy="115" r="5" fill="${badgeColor}"/>
    <text x="72" y="122" fill="#6E7482" font-family="ui-monospace, Menlo, sans-serif" font-size="20">${escapeXml(handleLine)}</text>
    ${bodySvg}
    ${mediaBlock}
  </svg>`;
  return { svg, width, height };
}

export function buildWebBookmarkSvg(
  title: string,
  domain: string,
  description?: string | null,
): SvgCardOutput {
  const titleLines = wrapLines(title || domain, 28, 3);
  const descLines = wrapLines(description ?? '', 40, 4);
  const titleSvg = titleLines
    .map(
      (line, i) =>
        `<text x="56" y="${190 + i * 48}" fill="#17191D" font-family="-apple-system, BlinkMacSystemFont, PingFang SC, Helvetica Neue, sans-serif" font-size="36" font-weight="700">${escapeXml(line)}</text>`,
    )
    .join('');
  const descTop = 190 + titleLines.length * 48 + 30;
  const descSvg = descLines
    .map(
      (line, i) =>
        `<text x="56" y="${descTop + i * 34}" fill="#596070" font-family="-apple-system, BlinkMacSystemFont, PingFang SC, Helvetica Neue, sans-serif" font-size="22">${escapeXml(line)}</text>`,
    )
    .join('');

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="800" height="640" viewBox="0 0 800 640">
    <rect width="800" height="640" fill="#F4F4F0"/>
    <rect x="28" y="28" width="744" height="584" rx="24" fill="#FFFFFF" stroke="#E5E4DE" stroke-width="2"/>
    <rect x="56" y="64" width="${Math.min(460, Math.max(120, domain.length * 13 + 38))}" height="38" rx="10" fill="#ECEEF4"/>
    <text x="74" y="89" fill="#445C94" font-family="ui-monospace, Menlo, sans-serif" font-size="18" font-weight="600">${escapeXml(domain.slice(0, 32))}</text>
    ${titleSvg}
    ${descSvg}
  </svg>`;
  return { svg, width: 800, height: 640 };
}

export function buildGenericBadgeSvg(
  title: string,
  ext: string,
  kindLabel: string,
): SvgCardOutput {
  const badge = (ext || kindLabel || 'FILE').toUpperCase().slice(0, 10);
  const titleLines = wrapLines(title, 24, 3);
  const titleSvg = titleLines
    .map(
      (line, i) =>
        `<text x="56" y="${380 + i * 44}" fill="#1A1C20" font-family="-apple-system, BlinkMacSystemFont, PingFang SC, Helvetica Neue, sans-serif" font-size="32" font-weight="700">${escapeXml(line)}</text>`,
    )
    .join('');
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="760" height="760" viewBox="0 0 760 760">
    <rect width="760" height="760" fill="#F2F1EC"/>
    <rect x="36" y="36" width="688" height="688" rx="28" fill="#FFFFFF" stroke="#E3E1D8" stroke-width="2"/>
    <rect x="56" y="68" width="${Math.max(110, badge.length * 20 + 40)}" height="54" rx="14" fill="#445C94"/>
    <text x="78" y="103" fill="#FFFFFF" font-family="ui-monospace, Menlo, sans-serif" font-size="24" font-weight="700">${escapeXml(badge)}</text>
    ${titleSvg}
    <text x="56" y="660" fill="#7A808E" font-family="-apple-system, BlinkMacSystemFont, PingFang SC, Helvetica Neue, sans-serif" font-size="22">${escapeXml(kindLabel)}</text>
  </svg>`;
  return { svg, width: 760, height: 760 };
}
