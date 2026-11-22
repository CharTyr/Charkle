import fs from 'node:fs';
import sharp, { type OverlayOptions } from 'sharp';
import type { AssetRecord, MediaKind, UUID } from '@charkle/shared';

export interface ContactSheetEntry {
  slot: number;
  asset: AssetRecord;
  thumbnailPath?: string | null;
  thumbnailBuffer?: Buffer | null;
}

export interface ContactSheetRenderOptions {
  maxCanvasWidth?: number;
  format?: 'png' | 'jpeg';
  jpegQuality?: number;
}

export interface ContactSheetBatch {
  data: Buffer;
  /** Convenience alias matching macOS `ContactSheetBatch.jpegData` when format is `'jpeg'`. */
  jpegData: Buffer;
  mimeType: 'image/png' | 'image/jpeg';
  slotToAssetID: Map<number, UUID>;
  orderedSlots: Array<{ slot: number; assetID: UUID }>;
  width: number;
  height: number;
}

function escapeXML(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function mediaBadgeLabel(kind: MediaKind): string | null {
  switch (kind) {
    case 'video':
      return 'VID';
    case 'animatedImage':
      return 'GIF';
    case 'document':
      return 'PDF';
    case 'webBookmark':
      return 'WEB';
    case 'designFile':
      return 'DES';
    case 'audio':
      return 'AUD';
    case 'model3D':
      return '3D';
    case 'image':
      return null;
  }
}

function sanitizeHex(hex?: string | null): string | null {
  if (!hex) return null;
  const cleaned = hex.trim().replace(/^#/, '');
  return /^[0-9a-fA-F]{6}$/.test(cleaned) ? `#${cleaned.toUpperCase()}` : null;
}

/**
 * Renders up to 16 numbered thumbnails (`#01`..`#16`) into a crisp studio-dark labeled grid
 * (PNG or JPEG) using `sharp` compositing and crisp SVG badges/borders.
 */
export const ContactSheetRenderer = {
  async render(
    entries: ContactSheetEntry[],
    options: ContactSheetRenderOptions = {},
  ): Promise<ContactSheetBatch | null> {
    const capped = entries.slice(0, 16);
    if (capped.length === 0) return null;

    const count = capped.length;
    const columns = count <= 4 ? Math.min(2, count) : count <= 9 ? 3 : 4;
    const rows = Math.ceil(count / columns);
    const margin = 18;
    const gap = 14;
    const canvasWidth = Math.max(640, Math.round(options.maxCanvasWidth ?? 1280));
    const cellWidth = Math.floor((canvasWidth - margin * 2 - gap * (columns - 1)) / columns);
    const cellHeight = Math.floor(cellWidth * 0.82);
    const canvasHeight = margin * 2 + rows * cellHeight + Math.max(0, rows - 1) * gap;

    const slotToAssetID = new Map<number, UUID>();
    const orderedSlots: Array<{ slot: number; assetID: UUID }> = [];
    const composites: OverlayOptions[] = [];

    const backgroundRects: string[] = [];
    const foregroundOverlays: string[] = [];

    for (let idx = 0; idx < capped.length; idx++) {
      const entry = capped[idx];
      const col = idx % columns;
      const row = Math.floor(idx / columns);
      const x = margin + col * (cellWidth + gap);
      const y = margin + row * (cellHeight + gap);

      slotToAssetID.set(entry.slot, entry.asset.id);
      orderedSlots.push({ slot: entry.slot, assetID: entry.asset.id });

      // Neutral tile card backing
      backgroundRects.push(
        `<rect x="${x}" y="${y}" width="${cellWidth}" height="${cellHeight}" rx="10" ry="10" fill="#25272E"/>`,
      );

      // Load and fit thumbnail image (with fallback dominant swatch rectangle)
      let rawThumb: Buffer | null = entry.thumbnailBuffer ?? null;
      if (!rawThumb && entry.thumbnailPath && fs.existsSync(entry.thumbnailPath)) {
        try {
          rawThumb = fs.readFileSync(entry.thumbnailPath);
        } catch {
          rawThumb = null;
        }
      }

      let placedImage = false;
      if (rawThumb && rawThumb.length > 0) {
        try {
          const insetW = Math.max(16, cellWidth - 8);
          const insetH = Math.max(16, cellHeight - 8);
          const resized = await sharp(rawThumb)
            .rotate()
            .resize(insetW, insetH, {
              fit: 'inside',
              withoutEnlargement: false,
            })
            .png()
            .toBuffer({ resolveWithObject: true });

          const imgW = resized.info.width;
          const imgH = resized.info.height;
          const drawX = x + Math.floor((cellWidth - imgW) / 2);
          const drawY = y + Math.floor((cellHeight - imgH) / 2);
          composites.push({
            input: resized.data,
            left: drawX,
            top: drawY,
          });
          placedImage = true;
        } catch {
          placedImage = false;
        }
      }

      if (!placedImage) {
        const swatchHex = sanitizeHex(entry.asset.dominantColors[0]?.hex) ?? '#3A3E48';
        backgroundRects.push(
          `<rect x="${x + 12}" y="${y + 12}" width="${Math.max(16, cellWidth - 24)}" height="${Math.max(16, cellHeight - 24)}" rx="6" ry="6" fill="${swatchHex}" fill-opacity="0.88"/>`,
        );
      }

      // Tile border
      foregroundOverlays.push(
        `<rect x="${x + 0.5}" y="${y + 0.5}" width="${cellWidth - 1}" height="${cellHeight - 1}" rx="10" ry="10" fill="none" stroke="rgba(255,255,255,0.16)" stroke-width="1"/>`,
      );

      // High-contrast top-left numbered pill `#01`..`#16`
      const badgeLabel = `#${String(entry.slot).padStart(2, '0')}`;
      const badgeFontSize = columns >= 4 ? 16 : 18;
      const badgeW = Math.ceil(badgeLabel.length * badgeFontSize * 0.68 + 16);
      const badgeH = Math.ceil(badgeFontSize + 10);
      const bx = x + 8;
      const by = y + 8;
      foregroundOverlays.push(
        `<rect x="${bx}" y="${by}" width="${badgeW}" height="${badgeH}" rx="${(badgeH * 0.45).toFixed(1)}" fill="rgba(0,0,0,0.88)" stroke="rgba(255,255,255,0.85)" stroke-width="1.25"/>`,
        `<text x="${bx + badgeW / 2}" y="${by + badgeH / 2 + badgeFontSize * 0.34}" text-anchor="middle" font-family="Menlo, Monaco, Consolas, monospace" font-size="${badgeFontSize}" font-weight="700" fill="#FFFFFF">${escapeXML(badgeLabel)}</text>`,
      );

      // Optional media badge top-right
      const mediaBadge = mediaBadgeLabel(entry.asset.mediaKind);
      if (mediaBadge) {
        const mf = 11;
        const mw = Math.ceil(mediaBadge.length * mf * 0.72 + 14);
        const mh = Math.ceil(mf + 8);
        const mx = x + cellWidth - 8 - mw;
        const my = y + 8;
        foregroundOverlays.push(
          `<rect x="${mx}" y="${my}" width="${mw}" height="${mh}" rx="${(mh * 0.45).toFixed(1)}" fill="rgba(30,92,200,0.92)" stroke="rgba(255,255,255,0.45)" stroke-width="1"/>`,
          `<text x="${mx + mw / 2}" y="${my + mh / 2 + mf * 0.35}" text-anchor="middle" font-family="Menlo, Monaco, Consolas, monospace" font-size="${mf}" font-weight="700" fill="#FFFFFF">${escapeXML(mediaBadge)}</text>`,
        );
      }

      // Subtle bottom title caption bar for clarity
      const shortTitle = entry.asset.title.trim().slice(0, 22);
      if (shortTitle) {
        const capH = 22;
        const cy = y + cellHeight - capH;
        foregroundOverlays.push(
          `<rect x="${x + 1}" y="${cy}" width="${cellWidth - 2}" height="${capH - 1}" rx="0" fill="rgba(0,0,0,0.58)"/>`,
          `<text x="${x + 10}" y="${cy + 15}" font-family="-apple-system, BlinkMacSystemFont, 'PingFang SC', 'Helvetica Neue', sans-serif" font-size="11" font-weight="500" fill="rgba(255,255,255,0.92)">${escapeXML(shortTitle)}</text>`,
        );
      }
    }

    const bgSvg = Buffer.from(
      `<svg xmlns="http://www.w3.org/2000/svg" width="${canvasWidth}" height="${canvasHeight}">${backgroundRects.join('')}</svg>`,
    );
    const fgSvg = Buffer.from(
      `<svg xmlns="http://www.w3.org/2000/svg" width="${canvasWidth}" height="${canvasHeight}">${foregroundOverlays.join('')}</svg>`,
    );

    const base = sharp({
      create: {
        width: canvasWidth,
        height: canvasHeight,
        channels: 4,
        background: { r: 24, g: 26, b: 31, alpha: 1 },
      },
    }).composite([{ input: bgSvg, left: 0, top: 0 }, ...composites, { input: fgSvg, left: 0, top: 0 }]);

    const format = options.format ?? 'png';
    const quality = Math.max(40, Math.min(100, Math.round((options.jpegQuality ?? 0.78) * 100)));

    let data: Buffer;
    let jpegData: Buffer;
    if (format === 'jpeg') {
      jpegData = await base.clone().flatten({ background: '#181A1F' }).jpeg({ quality }).toBuffer();
      data = jpegData;
    } else {
      data = await base.clone().png({ compressionLevel: 6 }).toBuffer();
      jpegData = await sharp(data).flatten({ background: '#181A1F' }).jpeg({ quality }).toBuffer();
    }

    return {
      data,
      jpegData,
      mimeType: format === 'jpeg' ? 'image/jpeg' : 'image/png',
      slotToAssetID,
      orderedSlots,
      width: canvasWidth,
      height: canvasHeight,
    };
  },
};
