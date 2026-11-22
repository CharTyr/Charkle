import sharp, { type OverlayOptions } from 'sharp';
import {
  clampCropRect,
  createDefaultMoodboardExportOptions,
  FULL_CROP_RECT,
  isLightHex,
  labFromHex,
  solveEditorialLayout,
  type AssetRecord,
  type BoardConnector,
  type BoardNode,
  type BoardPoint,
  type BoardRect,
  type ConnectorAnchor,
  type ConnectorStyle,
  type GroupTint,
  type InkStroke,
  type MoodboardDocument,
  type MoodboardExportFormat,
  type MoodboardExportOptions,
  type NoteStyle,
  type ThumbnailTier,
  type UUID,
} from '@charkle/shared';

export type ExportBackgroundMode = 'light' | 'dark' | 'transparent';

export interface ExtendedMoodboardExportOptions extends MoodboardExportOptions {
  backgroundMode?: ExportBackgroundMode;
}

export interface MoodboardImageExportResult {
  buffer: Buffer;
  mimeType: 'image/png' | 'image/jpeg';
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

function safeHex(hex: string | null | undefined, fallback: string): string {
  if (!hex) return fallback;
  const cleaned = hex.trim().replace(/^#/, '');
  return /^[0-9a-fA-F]{6}$/.test(cleaned) ? `#${cleaned.toUpperCase()}` : fallback;
}

function noteColors(style: NoteStyle): { bg: string; fg: string; border: string } {
  switch (style) {
    case 'paper':
      return { bg: '#FFFFFF', fg: '#1E2024', border: '#D9DBDE' };
    case 'ink':
      return { bg: '#1E2025', fg: '#F2F3F5', border: '#3A3D45' };
    case 'warm':
      return { bg: '#F6EFE2', fg: '#3B3124', border: '#C9B79C' };
    case 'sage':
      return { bg: '#E7EFE9', fg: '#233329', border: '#9AB5A3' };
    case 'slate':
      return { bg: '#E8EDF2', fg: '#212D38', border: '#9EB0C2' };
  }
}

function groupTintHex(tint: GroupTint): string {
  switch (tint) {
    case 'neutral':
      return '#7E848C';
    case 'sand':
      return '#B6976E';
    case 'sage':
      return '#6D8F78';
    case 'slate':
      return '#667C94';
    case 'terracotta':
      return '#BA6B55';
    case 'ocean':
      return '#4E7D96';
  }
}

function wrapTextLines(text: string, maxCharsPerLine: number, maxLines: number): string[] {
  const result: string[] = [];
  const paragraphs = text.split(/\r?\n/);
  const limit = Math.max(8, Math.floor(maxCharsPerLine));
  for (const para of paragraphs) {
    if (!para) {
      result.push('');
      continue;
    }
    let cur = '';
    let widthUnits = 0;
    for (const ch of para) {
      const charUnits = ch.charCodeAt(0) > 255 ? 1.85 : 1.0;
      if (widthUnits + charUnits > limit && cur.length > 0) {
        result.push(cur);
        cur = ch;
        widthUnits = charUnits;
        if (result.length >= maxLines) return result;
      } else {
        cur += ch;
        widthUnits += charUnits;
      }
    }
    if (cur) result.push(cur);
    if (result.length >= maxLines) return result.slice(0, maxLines);
  }
  return result.slice(0, maxLines);
}

function resolveAnchorPoint(
  rect: BoardRect,
  anchor: ConnectorAnchor,
  normalizedPoint: BoardPoint | null | undefined,
  other: BoardRect,
): BoardPoint {
  if (normalizedPoint) {
    const nx = Math.max(0, Math.min(1, normalizedPoint.x));
    const ny = Math.max(0, Math.min(1, normalizedPoint.y));
    return { x: rect.x + rect.width * nx, y: rect.y + rect.height * ny };
  }
  let resolved = anchor;
  if (anchor === 'auto') {
    const dx = other.x + other.width * 0.5 - (rect.x + rect.width * 0.5);
    const dy = other.y + other.height * 0.5 - (rect.y + rect.height * 0.5);
    if (Math.abs(dx) >= Math.abs(dy)) {
      resolved = dx >= 0 ? 'trailing' : 'leading';
    } else {
      resolved = dy >= 0 ? 'bottom' : 'top';
    }
  }
  switch (resolved) {
    case 'top':
      return { x: rect.x + rect.width * 0.5, y: rect.y };
    case 'bottom':
      return { x: rect.x + rect.width * 0.5, y: rect.y + rect.height };
    case 'leading':
      return { x: rect.x, y: rect.y + rect.height * 0.5 };
    case 'trailing':
      return { x: rect.x + rect.width, y: rect.y + rect.height * 0.5 };
    default:
      return { x: rect.x + rect.width * 0.5, y: rect.y + rect.height * 0.5 };
  }
}

function resolveConnectorPath(
  fromRect: BoardRect,
  fromAnchor: ConnectorAnchor,
  fromNorm: BoardPoint | null | undefined,
  toRect: BoardRect,
  toAnchor: ConnectorAnchor,
  toNorm: BoardPoint | null | undefined,
  style: ConnectorStyle,
): { start: BoardPoint; end: BoardPoint; c1: BoardPoint; c2: BoardPoint; mid: BoardPoint } {
  const start = resolveAnchorPoint(fromRect, fromAnchor, fromNorm, toRect);
  const end = resolveAnchorPoint(toRect, toAnchor, toNorm, fromRect);
  const dist = Math.max(48, Math.hypot(end.x - start.x, end.y - start.y) * 0.36);

  const normalOffset = (
    rect: BoardRect,
    pt: BoardPoint,
    isPinpoint: boolean,
    otherPt: BoardPoint,
  ): BoardPoint => {
    if (isPinpoint) {
      const dx = otherPt.x - pt.x;
      const dy = otherPt.y - pt.y;
      const len = Math.max(1, Math.hypot(dx, dy));
      const pull = Math.min(dist * 0.65, len * 0.35);
      return { x: (dx / len) * pull, y: (dy / len) * pull };
    }
    if (Math.abs(pt.y - rect.y) < 1.5) return { x: 0, y: -dist };
    if (Math.abs(pt.y - (rect.y + rect.height)) < 1.5) return { x: 0, y: dist };
    if (Math.abs(pt.x - rect.x) < 1.5) return { x: -dist, y: 0 };
    if (Math.abs(pt.x - (rect.x + rect.width)) < 1.5) return { x: dist, y: 0 };
    return { x: (end.x - start.x) * 0.25, y: 0 };
  };

  const n1 = normalOffset(fromRect, start, Boolean(fromNorm), end);
  const n2 = normalOffset(toRect, end, Boolean(toNorm), start);
  const c1 = { x: start.x + n1.x, y: start.y + n1.y };
  const c2 = { x: end.x + n2.x, y: end.y + n2.y };
  const mid =
    style === 'curved'
      ? {
          x: 0.125 * start.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * end.x,
          y: 0.125 * start.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * end.y,
        }
      : { x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5 };

  return { start, end, c1, c2, mid };
}

function renderConnectorSVG(
  connector: BoardConnector,
  fromRect: BoardRect,
  toRect: BoardRect,
): string {
  const { start, end, c1, c2, mid } = resolveConnectorPath(
    fromRect,
    connector.fromAnchor,
    connector.fromNormalizedPoint,
    toRect,
    connector.toAnchor,
    connector.toNormalizedPoint,
    connector.style,
  );
  const color = safeHex(connector.colorHex, '#5C6672');
  const dashAttr = connector.dashed ? ' stroke-dasharray="6 5"' : '';
  let d: string;
  let tangentSrc: BoardPoint;

  if (connector.style === 'curved') {
    d = `M ${start.x.toFixed(1)} ${start.y.toFixed(1)} C ${c1.x.toFixed(1)} ${c1.y.toFixed(1)} ${c2.x.toFixed(1)} ${c2.y.toFixed(1)} ${end.x.toFixed(1)} ${end.y.toFixed(1)}`;
    tangentSrc = c2;
  } else if (connector.style === 'elbow') {
    const midX = (start.x + end.x) * 0.5;
    d = `M ${start.x.toFixed(1)} ${start.y.toFixed(1)} L ${midX.toFixed(1)} ${start.y.toFixed(1)} L ${midX.toFixed(1)} ${end.y.toFixed(1)} L ${end.x.toFixed(1)} ${end.y.toFixed(1)}`;
    tangentSrc = { x: midX, y: end.y };
  } else {
    d = `M ${start.x.toFixed(1)} ${start.y.toFixed(1)} L ${end.x.toFixed(1)} ${end.y.toFixed(1)}`;
    tangentSrc = start;
  }

  const angle = Math.atan2(end.y - tangentSrc.y, end.x - tangentSrc.x);
  const arrowLen = 10;
  const spread = Math.PI / 6.5;
  const p1x = end.x - arrowLen * Math.cos(angle - spread);
  const p1y = end.y - arrowLen * Math.sin(angle - spread);
  const p2x = end.x - arrowLen * Math.cos(angle + spread);
  const p2y = end.y - arrowLen * Math.sin(angle + spread);

  const parts: string[] = [
    `<path d="${d}" fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"${dashAttr}/>`,
    `<path d="M ${p1x.toFixed(1)} ${p1y.toFixed(1)} L ${end.x.toFixed(1)} ${end.y.toFixed(1)} L ${p2x.toFixed(1)} ${p2y.toFixed(1)}" fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,
  ];

  if (connector.toNormalizedPoint) {
    parts.push(
      `<circle cx="${end.x.toFixed(1)}" cy="${end.y.toFixed(1)}" r="8" fill="${color}" fill-opacity="0.22"/>`,
      `<circle cx="${end.x.toFixed(1)}" cy="${end.y.toFixed(1)}" r="3.6" fill="${color}" stroke="#FFFFFF" stroke-opacity="0.92" stroke-width="1.4"/>`,
    );
  }

  if (connector.label?.trim()) {
    const label = connector.label.trim().slice(0, 32);
    const pillW = Math.max(44, label.length * 10 + 18);
    const pillH = 22;
    parts.push(
      `<rect x="${(mid.x - pillW / 2).toFixed(1)}" y="${(mid.y - pillH / 2).toFixed(1)}" width="${pillW}" height="${pillH}" rx="11" fill="#FFFFFF" fill-opacity="0.92" stroke="${color}" stroke-opacity="0.45" stroke-width="1"/>`,
      `<text x="${mid.x.toFixed(1)}" y="${(mid.y + 4).toFixed(1)}" text-anchor="middle" font-family="-apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif" font-size="11" font-weight="500" fill="${color}">${escapeXML(label)}</text>`,
    );
  }

  return parts.join('');
}

function renderInkStrokeSVG(stroke: InkStroke, offsetX: number, offsetY: number): string {
  if (stroke.points.length < 2) return '';
  const pts = stroke.points.map((p) => ({ x: p.x + offsetX, y: p.y + offsetY }));
  let d = `M ${pts[0].x.toFixed(1)} ${pts[0].y.toFixed(1)}`;
  if (pts.length === 2) {
    d += ` L ${pts[1].x.toFixed(1)} ${pts[1].y.toFixed(1)}`;
  } else {
    for (let i = 1; i < pts.length - 1; i++) {
      const mx = (pts[i].x + pts[i + 1].x) * 0.5;
      const my = (pts[i].y + pts[i + 1].y) * 0.5;
      d += ` Q ${pts[i].x.toFixed(1)} ${pts[i].y.toFixed(1)} ${mx.toFixed(1)} ${my.toFixed(1)}`;
    }
    const last = pts[pts.length - 1];
    d += ` L ${last.x.toFixed(1)} ${last.y.toFixed(1)}`;
  }
  const color = safeHex(stroke.colorHex, '#D95D48');
  const width = Math.max(1, stroke.lineWidth || 3.5);
  const opacity = Math.max(0.05, Math.min(1, stroke.opacity ?? 0.92));
  return `<path d="${d}" fill="none" stroke="${color}" stroke-opacity="${opacity.toFixed(2)}" stroke-width="${width.toFixed(1)}" stroke-linecap="round" stroke-linejoin="round"/>`;
}

export interface MoodboardExporterParams {
  document: MoodboardDocument;
  assetsByID: ReadonlyMap<UUID, AssetRecord> | Record<UUID, AssetRecord>;
  loadAssetBuffer: (assetID: UUID, preferredTier: ThumbnailTier) => Promise<Buffer | null>;
  format?: MoodboardExportFormat;
  containerWidth?: number;
  options?: Partial<ExtendedMoodboardExportOptions>;
}

function lookupAsset(
  assetsByID: ReadonlyMap<UUID, AssetRecord> | Record<UUID, AssetRecord>,
  id: UUID,
): AssetRecord | undefined {
  return assetsByID instanceof Map
    ? assetsByID.get(id)
    : (assetsByID as Record<UUID, AssetRecord>)[id];
}

/**
 * High-DPI 1x/2x Moodboard PNG/JPG exporter compositing Auto Editorial or Freeform layouts,
 * cropped/rotated/flipped asset images, styled notes, group frames, palette strips,
 * Bezier/elbow/straight connectors (incl. pinpoint callouts), and freehand ink strokes.
 */
export const MoodboardExporter = {
  async exportImage(params: MoodboardExporterParams): Promise<MoodboardImageExportResult> {
    const {
      document,
      assetsByID,
      loadAssetBuffer,
      format = 'png',
      containerWidth = 1120,
    } = params;

    const baseOpts = createDefaultMoodboardExportOptions(params.options ?? {});
    const bgMode: ExportBackgroundMode =
      params.options?.backgroundMode ?? (baseOpts.darkAppearance ? 'dark' : 'light');
    const darkAppearance = bgMode === 'dark';
    const isTransparent = bgMode === 'transparent' && format === 'png';
    const scale = Math.max(0.5, Math.min(3, baseOpts.scale || 2));
    const pad = Math.max(0, baseOpts.padding ?? 40);

    const resolvedFrames: Record<UUID, BoardRect> =
      document.mode.type === 'autoEditorial'
        ? solveEditorialLayout(document.nodes, document.mode.config, containerWidth, assetsByID)
            .frames
        : Object.fromEntries(document.nodes.map((n) => [n.id, n.frame]));

    // Tight bounding box across nodes + ink strokes
    let minX = Number.POSITIVE_INFINITY;
    let minY = Number.POSITIVE_INFINITY;
    let maxX = Number.NEGATIVE_INFINITY;
    let maxY = Number.NEGATIVE_INFINITY;

    for (const node of document.nodes) {
      const r = resolvedFrames[node.id];
      if (!r || r.width <= 0 || r.height <= 0) continue;
      minX = Math.min(minX, r.x);
      minY = Math.min(minY, r.y);
      maxX = Math.max(maxX, r.x + r.width);
      maxY = Math.max(maxY, r.y + r.height);
    }

    if (baseOpts.includeAnnotations) {
      for (const stroke of document.inkStrokes) {
        const lw = stroke.lineWidth || 3.5;
        for (const pt of stroke.points) {
          minX = Math.min(minX, pt.x - lw);
          minY = Math.min(minY, pt.y - lw);
          maxX = Math.max(maxX, pt.x + lw);
          maxY = Math.max(maxY, pt.y + lw);
        }
      }
    }

    if (!Number.isFinite(minX) || !Number.isFinite(minY) || maxX <= minX || maxY <= minY) {
      minX = 0;
      minY = 0;
      maxX = 960;
      maxY = 640;
    }

    const headerHeight =
      baseOpts.includePaletteStrip && document.extractedPalette.length > 0 ? 72 : 48;
    const contentW = maxX - minX;
    const contentH = maxY - minY;
    const canvasW = Math.max(640, Math.min(4800, Math.ceil(contentW + pad * 2)));
    const canvasH = Math.max(420, Math.min(4800, Math.ceil(contentH + pad * 2 + headerHeight)));

    // Cap absolute pixel dimension to 6400px to stay memory-safe
    const effectiveScale = Math.min(scale, 6400 / Math.max(canvasW, canvasH));
    const pixelW = Math.max(1, Math.round(canvasW * effectiveScale));
    const pixelH = Math.max(1, Math.round(canvasH * effectiveScale));

    const offsetX = pad - minX;
    const offsetY = pad + headerHeight - minY;

    const inkPrimary = darkAppearance ? 'rgba(255,255,255,0.92)' : 'rgba(20,22,26,0.88)';
    const inkSecondary = darkAppearance ? 'rgba(255,255,255,0.56)' : 'rgba(20,22,26,0.50)';

    const backdropSvgParts: string[] = [];
    const foregroundSvgParts: string[] = [];

    // Header title + subtitle + palette chips
    backdropSvgParts.push(
      `<text x="${pad}" y="${(pad * 0.65 + 20).toFixed(1)}" font-family="-apple-system, BlinkMacSystemFont, 'PingFang SC', 'Helvetica Neue', sans-serif" font-size="20" font-weight="600" fill="${inkPrimary}">${escapeXML(document.title || 'Charkle 情绪板')}</text>`,
    );
    if (document.subtitle.trim()) {
      backdropSvgParts.push(
        `<text x="${pad}" y="${(pad * 0.65 + 42).toFixed(1)}" font-family="-apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif" font-size="12" fill="${inkSecondary}">${escapeXML(document.subtitle.trim().slice(0, 120))}</text>`,
      );
    }
    if (baseOpts.includePaletteStrip && document.extractedPalette.length > 0) {
      const swatches = document.extractedPalette.slice(0, 7);
      const swW = 28;
      const swH = 20;
      const gap = 6;
      const totalW = swatches.length * swW + Math.max(0, swatches.length - 1) * gap;
      let sx = canvasW - pad - totalW;
      const sy = pad * 0.65 + 4;
      for (const sw of swatches) {
        const hex = safeHex(sw.hex, '#808080');
        backdropSvgParts.push(
          `<rect x="${sx.toFixed(1)}" y="${sy.toFixed(1)}" width="${swW}" height="${swH}" rx="6" fill="${hex}" stroke="rgba(0,0,0,0.12)" stroke-width="0.75"/>`,
        );
        sx += swW + gap;
      }
    }

    // Sort nodes: groupFrames first, then zIndex asc, then editorialOrder asc
    const orderedNodes = [...document.nodes].sort((lhs, rhs) => {
      const lGroup = lhs.kind.type === 'groupFrame' ? 0 : 1;
      const rGroup = rhs.kind.type === 'groupFrame' ? 0 : 1;
      if (lGroup !== rGroup) return lGroup - rGroup;
      if (lhs.zIndex !== rhs.zIndex) return lhs.zIndex - rhs.zIndex;
      return lhs.editorialOrder - rhs.editorialOrder;
    });

    const imageComposites: OverlayOptions[] = [];

    for (const node of orderedNodes) {
      const baseRect = resolvedFrames[node.id];
      if (!baseRect || baseRect.width <= 0 || baseRect.height <= 0) continue;
      const rect: BoardRect = {
        x: baseRect.x + offsetX,
        y: baseRect.y + offsetY,
        width: baseRect.width,
        height: baseRect.height,
      };
      const cx = rect.x + rect.width * 0.5;
      const cy = rect.y + rect.height * 0.5;
      const hasRot = Math.abs(node.rotationDegrees) > 0.1;
      const rotOpen = hasRot
        ? `<g transform="rotate(${node.rotationDegrees.toFixed(2)} ${cx.toFixed(1)} ${cy.toFixed(1)})">`
        : '';
      const rotClose = hasRot ? '</g>' : '';

      if (node.kind.type === 'groupFrame') {
        const tintColor = groupTintHex(node.kind.tint);
        const fillOpacity = darkAppearance ? '0.14' : '0.09';
        backdropSvgParts.push(
          `${rotOpen}<rect x="${rect.x.toFixed(1)}" y="${rect.y.toFixed(1)}" width="${rect.width.toFixed(1)}" height="${rect.height.toFixed(1)}" rx="16" fill="${tintColor}" fill-opacity="${fillOpacity}" stroke="${tintColor}" stroke-opacity="0.45" stroke-width="1.5" stroke-dasharray="6 4"/>` +
            `<circle cx="${(rect.x + 16).toFixed(1)}" cy="${(rect.y + 18).toFixed(1)}" r="4" fill="${tintColor}"/>` +
            `<text x="${(rect.x + 28).toFixed(1)}" y="${(rect.y + 22).toFixed(1)}" font-family="-apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif" font-size="13" font-weight="600" fill="${inkPrimary}">${escapeXML(node.kind.title || '分组区域')}</text>${rotClose}`,
        );
      } else if (node.kind.type === 'note') {
        const colors = noteColors(node.kind.style);
        const fontSize = Math.max(11, node.kind.fontSize || 14);
        const innerW = Math.max(40, rect.width - 28);
        const linesParts: string[] = [
          `${rotOpen}<rect x="${rect.x.toFixed(1)}" y="${rect.y.toFixed(1)}" width="${rect.width.toFixed(1)}" height="${rect.height.toFixed(1)}" rx="12" fill="${colors.bg}" stroke="${colors.border}" stroke-width="1"/>`,
        ];
        let textY = rect.y + 26;
        if (node.kind.title?.trim()) {
          linesParts.push(
            `<text x="${(rect.x + 14).toFixed(1)}" y="${textY.toFixed(1)}" font-family="-apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif" font-size="${Math.max(13, fontSize)}" font-weight="600" fill="${colors.fg}">${escapeXML(node.kind.title.trim().slice(0, 48))}</text>`,
          );
          textY += 22;
        }
        const bodyFont = Math.max(11, fontSize - 1);
        const lineHeight = Math.round(bodyFont * 1.45);
        const maxLines = Math.max(1, Math.floor((rect.y + rect.height - textY - 8) / lineHeight));
        const maxChars = Math.max(10, Math.floor(innerW / (bodyFont * 0.62)));
        const lines = wrapTextLines(node.kind.text, maxChars, maxLines);
        for (const line of lines) {
          linesParts.push(
            `<text x="${(rect.x + 14).toFixed(1)}" y="${textY.toFixed(1)}" font-family="-apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif" font-size="${bodyFont}" fill="${colors.fg}" fill-opacity="0.88">${escapeXML(line)}</text>`,
          );
          textY += lineHeight;
        }
        linesParts.push(rotClose);
        foregroundSvgParts.push(linesParts.join(''));
      } else if (node.kind.type === 'paletteStrip') {
        const activeColors =
          node.kind.autoSyncWithBoard && document.extractedPalette.length > 0
            ? document.extractedPalette
            : node.kind.colors;
        const list = activeColors.length > 0 ? activeColors : [labFromHex('#808080')];
        const segW = rect.width / list.length;
        const clipId = `clip-pal-${node.id.replace(/[^a-zA-Z0-9]/g, '')}`;
        const parts: string[] = [
          `${rotOpen}<defs><clipPath id="${clipId}"><rect x="${rect.x.toFixed(1)}" y="${rect.y.toFixed(1)}" width="${rect.width.toFixed(1)}" height="${rect.height.toFixed(1)}" rx="12"/></clipPath></defs><g clip-path="url(#${clipId})">`,
        ];
        list.forEach((c, idx) => {
          const hex = safeHex(c.hex, '#808080');
          const sx = rect.x + idx * segW;
          const labelFill = isLightHex(hex) ? 'rgba(24,24,27,0.82)' : 'rgba(248,248,250,0.92)';
          parts.push(
            `<rect x="${sx.toFixed(1)}" y="${rect.y.toFixed(1)}" width="${(segW + 0.6).toFixed(1)}" height="${rect.height.toFixed(1)}" fill="${hex}"/>`,
            `<text x="${(sx + 8).toFixed(1)}" y="${(rect.y + rect.height - 8).toFixed(1)}" font-family="Menlo, Monaco, monospace" font-size="10" font-weight="600" fill="${labelFill}">${hex}</text>`,
          );
        });
        parts.push(
          `</g><rect x="${rect.x.toFixed(1)}" y="${rect.y.toFixed(1)}" width="${rect.width.toFixed(1)}" height="${rect.height.toFixed(1)}" rx="12" fill="none" stroke="rgba(0,0,0,0.12)" stroke-width="1"/>${rotClose}`,
        );
        foregroundSvgParts.push(parts.join(''));
      } else if (node.kind.type === 'assetRef') {
        const asset = lookupAsset(assetsByID, node.kind.assetID);
        const rawBuf =
          (await loadAssetBuffer(node.kind.assetID, 'preview1400')) ??
          (await loadAssetBuffer(node.kind.assetID, 'grid520'));

        const targetW = Math.max(4, Math.round(rect.width * effectiveScale));
        const targetH = Math.max(4, Math.round(rect.height * effectiveScale));
        let rendered = false;

        if (rawBuf && rawBuf.length > 0) {
          try {
            let pipe = sharp(rawBuf).rotate();
            const meta = await pipe.metadata();
            const imgW = meta.width ?? 0;
            const imgH = meta.height ?? 0;

            const crop = node.kind.crop;
            if (
              crop &&
              imgW > 0 &&
              imgH > 0 &&
              crop.width > 0.04 &&
              crop.height > 0.04 &&
              !(
                crop.x === FULL_CROP_RECT.x &&
                crop.y === FULL_CROP_RECT.y &&
                crop.width === FULL_CROP_RECT.width &&
                crop.height === FULL_CROP_RECT.height
              )
            ) {
              const c = clampCropRect(crop);
              const left = Math.max(0, Math.min(imgW - 1, Math.floor(c.x * imgW)));
              const top = Math.max(0, Math.min(imgH - 1, Math.floor(c.y * imgH)));
              const width = Math.max(4, Math.min(imgW - left, Math.round(c.width * imgW)));
              const height = Math.max(4, Math.min(imgH - top, Math.round(c.height * imgH)));
              if (width >= 4 && height >= 4) {
                pipe = pipe.extract({ left, top, width, height });
              }
            }

            if (node.flipHorizontal) pipe = pipe.flop();
            if (node.flipVertical) pipe = pipe.flip();

            const cornerR = Math.round(12 * effectiveScale);
            const maskSvg = Buffer.from(
              `<svg xmlns="http://www.w3.org/2000/svg" width="${targetW}" height="${targetH}"><rect x="0" y="0" width="${targetW}" height="${targetH}" rx="${cornerR}" ry="${cornerR}" fill="#FFFFFF"/></svg>`,
            );

            let cardBuf = await pipe
              .resize(targetW, targetH, { fit: 'cover', position: 'centre' })
              .ensureAlpha()
              .composite([{ input: maskSvg, blend: 'dest-in' }])
              .png()
              .toBuffer();

            let drawW = targetW;
            let drawH = targetH;
            if (hasRot) {
              const rotated = await sharp(cardBuf)
                .rotate(node.rotationDegrees, { background: { r: 0, g: 0, b: 0, alpha: 0 } })
                .png()
                .toBuffer({ resolveWithObject: true });
              cardBuf = rotated.data;
              drawW = rotated.info.width;
              drawH = rotated.info.height;
            }

            const centerPxX = Math.round(cx * effectiveScale);
            const centerPxY = Math.round(cy * effectiveScale);
            const leftPx = Math.round(centerPxX - drawW / 2);
            const topPx = Math.round(centerPxY - drawH / 2);

            // Clamp compositing bounds cleanly inside canvas
            if (leftPx < pixelW && topPx < pixelH && leftPx + drawW > 0 && topPx + drawH > 0) {
              const cropLeft = Math.max(0, -leftPx);
              const cropTop = Math.max(0, -topPx);
              const visW = Math.min(drawW - cropLeft, pixelW - Math.max(0, leftPx));
              const visH = Math.min(drawH - cropTop, pixelH - Math.max(0, topPx));
              if (visW > 0 && visH > 0) {
                const finalCard =
                  cropLeft > 0 || cropTop > 0 || visW < drawW || visH < drawH
                    ? await sharp(cardBuf)
                        .extract({ left: cropLeft, top: cropTop, width: visW, height: visH })
                        .png()
                        .toBuffer()
                    : cardBuf;
                imageComposites.push({
                  input: finalCard,
                  left: Math.max(0, leftPx),
                  top: Math.max(0, topPx),
                });
                rendered = true;
              }
            }
          } catch {
            rendered = false;
          }
        }

        if (!rendered) {
          const fallbackHex = safeHex(
            asset?.dominantColors[0]?.hex,
            darkAppearance ? '#2B2F36' : '#DFDDD7',
          );
          const titleColor = isLightHex(fallbackHex) ? 'rgba(20,20,24,0.78)' : 'rgba(255,255,255,0.88)';
          backdropSvgParts.push(
            `${rotOpen}<rect x="${rect.x.toFixed(1)}" y="${rect.y.toFixed(1)}" width="${rect.width.toFixed(1)}" height="${rect.height.toFixed(1)}" rx="12" fill="${fallbackHex}"/>` +
              (asset?.title
                ? `<text x="${(rect.x + 12).toFixed(1)}" y="${(rect.y + 26).toFixed(1)}" font-family="-apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif" font-size="12" font-weight="500" fill="${titleColor}">${escapeXML(asset.title.slice(0, 28))}</text>`
                : '') +
              rotClose,
          );
        }
      }
    }

    // Annotations layer (connectors + ink strokes)
    if (baseOpts.includeAnnotations) {
      for (const connector of document.connectors) {
        const fromBase = resolvedFrames[connector.fromNodeID];
        const toBase = resolvedFrames[connector.toNodeID];
        if (!fromBase || !toBase) continue;
        const fromRect: BoardRect = {
          x: fromBase.x + offsetX,
          y: fromBase.y + offsetY,
          width: fromBase.width,
          height: fromBase.height,
        };
        const toRect: BoardRect = {
          x: toBase.x + offsetX,
          y: toBase.y + offsetY,
          width: toBase.width,
          height: toBase.height,
        };
        foregroundSvgParts.push(renderConnectorSVG(connector, fromRect, toRect));
      }

      for (const stroke of document.inkStrokes) {
        if (stroke.points.length >= 2) {
          foregroundSvgParts.push(renderInkStrokeSVG(stroke, offsetX, offsetY));
        }
      }
    }

    const backdropSvg = Buffer.from(
      `<svg xmlns="http://www.w3.org/2000/svg" width="${pixelW}" height="${pixelH}" viewBox="0 0 ${canvasW} ${canvasH}">${backdropSvgParts.join('')}</svg>`,
    );
    const foregroundSvg = Buffer.from(
      `<svg xmlns="http://www.w3.org/2000/svg" width="${pixelW}" height="${pixelH}" viewBox="0 0 ${canvasW} ${canvasH}">${foregroundSvgParts.join('')}</svg>`,
    );

    const bgRgba = isTransparent
      ? { r: 0, g: 0, b: 0, alpha: 0 }
      : darkAppearance
        ? { r: 20, g: 21, b: 23, alpha: 1 } // #141517
        : { r: 246, g: 246, b: 245, alpha: 1 }; // #F6F6F5

    const overlays: OverlayOptions[] = [
      { input: backdropSvg, left: 0, top: 0 },
      ...imageComposites,
    ];
    if (foregroundSvgParts.length > 0) {
      overlays.push({ input: foregroundSvg, left: 0, top: 0 });
    }

    let canvas = sharp({
      create: {
        width: pixelW,
        height: pixelH,
        channels: 4,
        background: bgRgba,
      },
    }).composite(overlays);

    if (format === 'jpeg') {
      const buffer = await canvas
        .flatten({ background: darkAppearance ? '#141517' : '#F6F6F5' })
        .jpeg({ quality: 92 })
        .toBuffer();
      return { buffer, mimeType: 'image/jpeg', width: pixelW, height: pixelH };
    }

    const buffer = await canvas.png({ compressionLevel: 6 }).toBuffer();
    return { buffer, mimeType: 'image/png', width: pixelW, height: pixelH };
  },
};
