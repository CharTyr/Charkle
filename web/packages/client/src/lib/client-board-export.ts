import JSZip from 'jszip';
import {
  clampCropRect,
  createDefaultMoodboardExportOptions,
  FULL_CROP_RECT,
  isLightHex,
  labFromHex,
  mediaKindLocalizedLabel,
  solveEditorialLayout,
  type AssetRecord,
  type BoardConnector,
  type BoardNode,
  type BoardPoint,
  type BoardRect,
  type ConnectorAnchor,
  type FigmaBridgeBoardManifest,
  type FigmaBridgeObject,
  type FigmaBridgeObjectGeometry,
  type FigmaBridgeReport,
  type FigmaBridgeTile,
  type GroupTint,
  type InkStroke,
  type MoodboardDocument,
  type MoodboardExportFormat,
  type MoodboardExportOptions,
  type NoteStyle,
  type UUID,
} from '@charkle/shared';
import { originalMediaURL, thumbnailURL } from '../api/client';

export type ExportBackgroundMode = 'light' | 'dark' | 'transparent';

export interface ExportProgressInfo {
  stage: string;
  completed: number;
  total: number;
}

export interface ClientMoodboardImageExportParams {
  document: MoodboardDocument;
  assetsByID: ReadonlyMap<UUID, AssetRecord> | Record<UUID, AssetRecord>;
  format?: MoodboardExportFormat;
  backgroundMode?: ExportBackgroundMode;
  containerWidth?: number;
  options?: Partial<MoodboardExportOptions>;
  onProgress?: (progress: ExportProgressInfo) => void;
}

export interface ClientMoodboardImageExportResult {
  blob: Blob;
  filename: string;
  width: number;
  height: number;
}

export interface ClientFigmaBridgeExportParams {
  document: MoodboardDocument;
  assetsByID: ReadonlyMap<UUID, AssetRecord> | Record<UUID, AssetRecord>;
  containerWidth?: number;
  options?: Partial<MoodboardExportOptions>;
  onProgress?: (progress: ExportProgressInfo) => void;
}

export interface ClientFigmaBridgeExportResult {
  blob: Blob;
  filename: string;
  manifest: FigmaBridgeBoardManifest;
  report: FigmaBridgeReport;
}

const TILE_LIMIT = 4096;
const MAX_CANVAS_EDGE = 6400;
const MAX_CANVAS_AREA = 32_000_000;
const SYSTEM_SANS_FONT =
  '-apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Noto Sans SC", "Helvetica Neue", sans-serif';
const SYSTEM_MONO_FONT = 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace';

// MARK: - Shared Helpers

function lookupAsset(
  assetsByID: ReadonlyMap<UUID, AssetRecord> | Record<UUID, AssetRecord>,
  id: UUID,
): AssetRecord | undefined {
  return assetsByID instanceof Map
    ? assetsByID.get(id)
    : (assetsByID as Record<UUID, AssetRecord>)[id];
}

function safeHex(hex: string | null | undefined, fallback: string): string {
  if (!hex) return fallback;
  const cleaned = hex.trim().replace(/^#/, '');
  return /^[0-9a-fA-F]{6}$/.test(cleaned) ? `#${cleaned.toUpperCase()}` : fallback;
}

function hexToRgba(hex: string, alpha: number): string {
  const clean = safeHex(hex, '#808080').slice(1);
  const r = Number.parseInt(clean.slice(0, 2), 16);
  const g = Number.parseInt(clean.slice(2, 4), 16);
  const b = Number.parseInt(clean.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

function sanitizeFilenameSlug(title: string): string {
  const cleaned = (title || 'moodboard')
    .replace(/[/\\:*?"<>|\x00-\x1f]/g, '-')
    .trim()
    .slice(0, 64);
  return cleaned || 'moodboard';
}

function sanitizeSafeToken(input: string): string {
  return input.replace(/[^A-Za-z0-9._-]/g, '_');
}

function extractExtension(fileName?: string | null): string {
  if (!fileName) return '';
  const base = fileName.split(/[\\/]/).pop() ?? '';
  const dot = base.lastIndexOf('.');
  if (dot <= 0 || dot === base.length - 1) return '';
  return base
    .slice(dot + 1)
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');
}

function noteColors(style: NoteStyle): { bg: string; fg: string; border: string } {
  switch (style) {
    case 'paper':
      return { bg: '#FFFFFF', fg: '#1D1F23', border: '#D9DBDE' };
    case 'ink':
      return { bg: '#1D1F24', fg: '#F1F2F4', border: '#3A3D45' };
    case 'warm':
      return { bg: '#F7F0E4', fg: '#392F22', border: '#C9B79C' };
    case 'sage':
      return { bg: '#E8F0EA', fg: '#203227', border: '#9AB5A3' };
    case 'slate':
      return { bg: '#E9EEF3', fg: '#1F2B36', border: '#9EB0C2' };
  }
}

function groupTintHex(tint: GroupTint): string {
  switch (tint) {
    case 'neutral':
      return '#7D838B';
    case 'sand':
      return '#B5956B';
    case 'sage':
      return '#6B8E76';
    case 'slate':
      return '#627A94';
    case 'terracotta':
      return '#BA6B55';
    case 'ocean':
      return '#4D7E97';
  }
}

function resolveOrderedNodes(document: MoodboardDocument): BoardNode[] {
  return [...document.nodes].sort((lhs, rhs) => {
    const lGroup = lhs.kind.type === 'groupFrame' ? 0 : 1;
    const rGroup = rhs.kind.type === 'groupFrame' ? 0 : 1;
    if (lGroup !== rGroup) return lGroup - rGroup;
    if (lhs.zIndex !== rhs.zIndex) return lhs.zIndex - rhs.zIndex;
    return lhs.editorialOrder - rhs.editorialOrder;
  });
}

function resolveDocumentFrames(
  document: MoodboardDocument,
  assetsByID: ReadonlyMap<UUID, AssetRecord> | Record<UUID, AssetRecord>,
  containerWidth: number,
): Record<UUID, BoardRect> {
  if (document.mode.type === 'autoEditorial') {
    return solveEditorialLayout(document.nodes, document.mode.config, containerWidth, assetsByID)
      .frames;
  }
  return Object.fromEntries(document.nodes.map((n) => [n.id, n.frame]));
}

// MARK: - SHA-256 (Web Crypto primary + pure-TS fallback for non-HTTPS LAN hosts)

const SHA256_K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

function sha256FallbackHex(data: Uint8Array): string {
  const rotr = (x: number, n: number) => (x >>> n) | (x << (32 - n));
  let h0 = 0x6a09e667;
  let h1 = 0xbb67ae85;
  let h2 = 0x3c6ef372;
  let h3 = 0xa54ff53a;
  let h4 = 0x510e527f;
  let h5 = 0x9b05688c;
  let h6 = 0x1f83d9ab;
  let h7 = 0x5be0cd19;

  const bitLen = data.length * 8;
  const padLen = ((56 - ((data.length + 1) % 64)) + 64) % 64;
  const padded = new Uint8Array(data.length + 1 + padLen + 8);
  padded.set(data);
  padded[data.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 8, Math.floor(bitLen / 0x100000000), false);
  view.setUint32(padded.length - 4, bitLen >>> 0, false);

  const w = new Uint32Array(64);
  for (let offset = 0; offset < padded.length; offset += 64) {
    for (let i = 0; i < 16; i++) {
      w[i] = view.getUint32(offset + i * 4, false);
    }
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }

    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;
    let f = h5;
    let g = h6;
    let h = h7;

    for (let i = 0; i < 64; i++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (h + S1 + ch + SHA256_K[i] + w[i]) >>> 0;
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) >>> 0;

      h = g;
      g = f;
      f = e;
      e = (d + t1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) >>> 0;
    }

    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
    h5 = (h5 + f) >>> 0;
    h6 = (h6 + g) >>> 0;
    h7 = (h7 + h) >>> 0;
  }

  return [h0, h1, h2, h3, h4, h5, h6, h7]
    .map((v) => v.toString(16).padStart(8, '0'))
    .join('');
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  if (typeof globalThis.crypto?.subtle?.digest === 'function') {
    const copy = new Uint8Array(bytes.byteLength);
    copy.set(bytes);
    const digest = await globalThis.crypto.subtle.digest('SHA-256', copy.buffer);
    return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
  }
  return sha256FallbackHex(bytes);
}

async function shortStableHash(input: string): Promise<string> {
  const hex = await sha256Hex(new TextEncoder().encode(input));
  return hex.slice(0, 8);
}

// MARK: - GIF Animation Detection & Image Decoding

/**
 * Counts image descriptor frames in a GIF87a/GIF89a byte stream without external codecs.
 */
function countGifFrames(bytes: Uint8Array): number {
  if (bytes.length < 14) return 0;
  const sig =
    String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]);
  if (sig !== 'GIF87a' && sig !== 'GIF89a') return 0;

  let pos = 13;
  const packed = bytes[10];
  if (packed & 0x80) {
    const gctSize = 3 * (1 << ((packed & 0x07) + 1));
    pos += gctSize;
  }

  let frames = 0;
  while (pos < bytes.length) {
    const block = bytes[pos++];
    if (block === 0x3b) break; // Trailer
    if (block === 0x2c) {
      // Image Descriptor
      frames++;
      if (frames > 1) return frames;
      if (pos + 9 > bytes.length) break;
      const imgPacked = bytes[pos + 8];
      pos += 9;
      if (imgPacked & 0x80) {
        pos += 3 * (1 << ((imgPacked & 0x07) + 1));
      }
      pos += 1; // LZW minimum code size
      while (pos < bytes.length) {
        const subLen = bytes[pos++];
        if (subLen === 0) break;
        pos += subLen;
      }
    } else if (block === 0x21) {
      // Extension block
      pos += 1; // label
      while (pos < bytes.length) {
        const subLen = bytes[pos++];
        if (subLen === 0) break;
        pos += subLen;
      }
    } else {
      break;
    }
  }
  return frames;
}

interface DecodedImage {
  source: CanvasImageSource;
  width: number;
  height: number;
  cleanup: () => void;
}

function loadHTMLImage(blob: Blob): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(blob);
    const img = new Image();
    img.decoding = 'async';
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve(img);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error('Image decode failed'));
    };
    img.src = url;
  });
}

async function decodeImageBytes(bytes: Uint8Array, mimeHint?: string): Promise<DecodedImage | null> {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  const mime = mimeHint || 'application/octet-stream';
  const blob = new Blob([copy.buffer], { type: mime });
  const isSvg = mime.toLowerCase().includes('svg');

  if (!isSvg && typeof createImageBitmap === 'function') {
    try {
      const bitmap = await createImageBitmap(blob);
      if (bitmap.width > 0 && bitmap.height > 0) {
        return {
          source: bitmap,
          width: bitmap.width,
          height: bitmap.height,
          cleanup: () => bitmap.close(),
        };
      }
      bitmap.close();
    } catch {
      // Fall back to HTMLImageElement
    }
  }

  try {
    const img = await loadHTMLImage(blob);
    const width = img.naturalWidth || (isSvg ? 1200 : 0);
    const height = img.naturalHeight || (isSvg ? 900 : 0);
    if (width <= 0 || height <= 0) return null;
    return { source: img, width, height, cleanup: () => {} };
  } catch {
    return null;
  }
}

async function fetchAuthenticatedBytes(
  url: string,
): Promise<{ bytes: Uint8Array; contentType: string } | null> {
  try {
    const res = await fetch(url, { credentials: 'include' });
    if (!res.ok) return null;
    const contentType = res.headers.get('Content-Type') ?? '';
    const buf = await res.arrayBuffer();
    if (buf.byteLength === 0) return null;
    return { bytes: new Uint8Array(buf), contentType };
  } catch {
    return null;
  }
}

function canvasToBlob(canvas: HTMLCanvasElement, mimeType: string, quality?: number): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => {
        if (blob) resolve(blob);
        else reject(new Error('浏览器画布导出失败'));
      },
      mimeType,
      quality,
    );
  });
}

// MARK: - Canvas 2D Drawing Primitives

function roundedRectPath(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  radius: number,
): void {
  const r = Math.max(0, Math.min(radius, w * 0.5, h * 0.5));
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

function rotatePoint(pt: BoardPoint, center: BoardPoint, degrees: number): BoardPoint {
  if (Math.abs(degrees) < 0.01) return pt;
  const rad = (degrees * Math.PI) / 180;
  const cos = Math.cos(rad);
  const sin = Math.sin(rad);
  const dx = pt.x - center.x;
  const dy = pt.y - center.y;
  return {
    x: center.x + dx * cos - dy * sin,
    y: center.y + dx * sin + dy * cos,
  };
}

function wrapTextToWidth(
  ctx: CanvasRenderingContext2D,
  text: string,
  maxWidth: number,
  maxLines: number,
): string[] {
  if (maxLines <= 0 || maxWidth <= 8) return [];
  const paragraphs = text.split(/\r?\n/);
  const lines: string[] = [];

  for (const para of paragraphs) {
    if (lines.length >= maxLines) break;
    if (!para) {
      lines.push('');
      continue;
    }

    let current = '';
    const chars = Array.from(para);
    for (let i = 0; i < chars.length; i++) {
      const ch = chars[i];
      const next = current + ch;
      if (ctx.measureText(next).width > maxWidth && current.length > 0) {
        // Prefer breaking at last ASCII space for Latin text if available near the end
        const lastSpace = current.lastIndexOf(' ');
        if (
          ch.charCodeAt(0) < 256 &&
          lastSpace > Math.floor(current.length * 0.55) &&
          lastSpace < current.length - 1
        ) {
          lines.push(current.slice(0, lastSpace));
          current = current.slice(lastSpace + 1) + ch;
        } else {
          lines.push(current);
          current = ch;
        }
        if (lines.length >= maxLines) break;
      } else {
        current = next;
      }
    }
    if (current && lines.length < maxLines) {
      lines.push(current);
    }
  }

  return lines.slice(0, maxLines);
}

function resolveAnchorWorldPoint(
  rect: BoardRect,
  rotationDegrees: number,
  flipHorizontal: boolean,
  flipVertical: boolean,
  anchor: ConnectorAnchor,
  normalizedPoint: BoardPoint | null | undefined,
  otherCenter: BoardPoint,
): { point: BoardPoint; resolvedAnchor: Exclude<ConnectorAnchor, 'auto'>; isPinpoint: boolean } {
  const center = { x: rect.x + rect.width * 0.5, y: rect.y + rect.height * 0.5 };

  if (normalizedPoint) {
    const nx = flipHorizontal ? 1 - normalizedPoint.x : normalizedPoint.x;
    const ny = flipVertical ? 1 - normalizedPoint.y : normalizedPoint.y;
    const localPt = {
      x: rect.x + Math.max(0.02, Math.min(0.98, nx)) * rect.width,
      y: rect.y + Math.max(0.02, Math.min(0.98, ny)) * rect.height,
    };
    const pt = rotatePoint(localPt, center, rotationDegrees);
    const dx = otherCenter.x - pt.x;
    const dy = otherCenter.y - pt.y;
    const resolved: Exclude<ConnectorAnchor, 'auto'> =
      Math.abs(dx) >= Math.abs(dy) ? (dx >= 0 ? 'trailing' : 'leading') : dy >= 0 ? 'bottom' : 'top';
    return { point: pt, resolvedAnchor: resolved, isPinpoint: true };
  }

  let resolved: Exclude<ConnectorAnchor, 'auto'>;
  if (anchor === 'auto') {
    const dx = otherCenter.x - center.x;
    const dy = otherCenter.y - center.y;
    if (Math.abs(dx) >= Math.abs(dy)) {
      resolved = dx >= 0 ? 'trailing' : 'leading';
    } else {
      resolved = dy >= 0 ? 'bottom' : 'top';
    }
  } else {
    resolved = anchor;
  }

  let rawPt: BoardPoint;
  switch (resolved) {
    case 'top':
      rawPt = { x: center.x, y: rect.y };
      break;
    case 'bottom':
      rawPt = { x: center.x, y: rect.y + rect.height };
      break;
    case 'leading':
      rawPt = { x: rect.x, y: center.y };
      break;
    case 'trailing':
      rawPt = { x: rect.x + rect.width, y: center.y };
      break;
  }

  return {
    point: rotatePoint(rawPt, center, rotationDegrees),
    resolvedAnchor: resolved,
    isPinpoint: false,
  };
}

function drawConnectorOnCanvas(
  ctx: CanvasRenderingContext2D,
  connector: BoardConnector,
  fromNode: BoardNode,
  fromRect: BoardRect,
  toNode: BoardNode,
  toRect: BoardRect,
  darkAppearance: boolean,
): void {
  const fromCenter = { x: fromRect.x + fromRect.width * 0.5, y: fromRect.y + fromRect.height * 0.5 };
  const toCenter = { x: toRect.x + toRect.width * 0.5, y: toRect.y + toRect.height * 0.5 };

  const fromRes = resolveAnchorWorldPoint(
    fromRect,
    fromNode.rotationDegrees,
    fromNode.flipHorizontal,
    fromNode.flipVertical,
    connector.fromAnchor,
    connector.fromNormalizedPoint,
    toCenter,
  );
  const toRes = resolveAnchorWorldPoint(
    toRect,
    toNode.rotationDegrees,
    toNode.flipHorizontal,
    toNode.flipVertical,
    connector.toAnchor,
    connector.toNormalizedPoint,
    fromCenter,
  );

  const start = fromRes.point;
  const end = toRes.point;
  const color = safeHex(connector.colorHex, '#5C6672');
  const dist = Math.hypot(end.x - start.x, end.y - start.y);

  const normalVec = (anchor: Exclude<ConnectorAnchor, 'auto'>): BoardPoint => {
    switch (anchor) {
      case 'top':
        return { x: 0, y: -1 };
      case 'bottom':
        return { x: 0, y: 1 };
      case 'leading':
        return { x: -1, y: 0 };
      case 'trailing':
        return { x: 1, y: 0 };
    }
  };

  let mid: BoardPoint;
  let endAngleRad: number;

  ctx.save();
  ctx.strokeStyle = color;
  ctx.lineWidth = 2;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.setLineDash(connector.dashed ? [6, 5] : []);

  ctx.beginPath();
  ctx.moveTo(start.x, start.y);

  if (connector.style === 'straight') {
    ctx.lineTo(end.x, end.y);
    mid = { x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5 };
    endAngleRad = Math.atan2(end.y - start.y, end.x - start.x);
  } else if (connector.style === 'elbow') {
    const horizontalFirst =
      fromRes.resolvedAnchor === 'leading' || fromRes.resolvedAnchor === 'trailing';
    const midX = (start.x + end.x) * 0.5;
    const midY = (start.y + end.y) * 0.5;
    let prevPt: BoardPoint;
    if (horizontalFirst) {
      ctx.lineTo(midX, start.y);
      ctx.lineTo(midX, end.y);
      ctx.lineTo(end.x, end.y);
      prevPt = { x: midX, y: end.y };
    } else {
      ctx.lineTo(start.x, midY);
      ctx.lineTo(end.x, midY);
      ctx.lineTo(end.x, end.y);
      prevPt = { x: end.x, y: midY };
    }
    mid = { x: midX, y: midY };
    endAngleRad =
      end.x !== prevPt.x || end.y !== prevPt.y
        ? Math.atan2(end.y - prevPt.y, end.x - prevPt.x)
        : Math.atan2(end.y - start.y, end.x - start.x);
  } else {
    const tangent = Math.max(38, Math.min(180, dist * 0.36));
    const n1 = normalVec(fromRes.resolvedAnchor);
    const n2 = normalVec(toRes.resolvedAnchor);
    const cp1 = { x: start.x + n1.x * tangent, y: start.y + n1.y * tangent };
    const cp2 = { x: end.x + n2.x * tangent, y: end.y + n2.y * tangent };
    ctx.bezierCurveTo(cp1.x, cp1.y, cp2.x, cp2.y, end.x, end.y);
    mid = {
      x: 0.125 * start.x + 0.375 * cp1.x + 0.375 * cp2.x + 0.125 * end.x,
      y: 0.125 * start.y + 0.375 * cp1.y + 0.375 * cp2.y + 0.125 * end.y,
    };
    endAngleRad = Math.atan2(end.y - cp2.y, end.x - cp2.x);
  }
  ctx.stroke();

  // Arrowhead (solid)
  ctx.setLineDash([]);
  const arrowLen = 10;
  const spread = Math.PI / 6.5;
  ctx.beginPath();
  ctx.moveTo(
    end.x - arrowLen * Math.cos(endAngleRad - spread),
    end.y - arrowLen * Math.sin(endAngleRad - spread),
  );
  ctx.lineTo(end.x, end.y);
  ctx.lineTo(
    end.x - arrowLen * Math.cos(endAngleRad + spread),
    end.y - arrowLen * Math.sin(endAngleRad + spread),
  );
  ctx.stroke();

  // Pinpoint dot callout
  if (toRes.isPinpoint) {
    ctx.beginPath();
    ctx.arc(end.x, end.y, 8, 0, Math.PI * 2);
    ctx.fillStyle = hexToRgba(color, 0.22);
    ctx.fill();

    ctx.beginPath();
    ctx.arc(end.x, end.y, 3.6, 0, Math.PI * 2);
    ctx.fillStyle = color;
    ctx.fill();
    ctx.strokeStyle = 'rgba(255,255,255,0.92)';
    ctx.lineWidth = 1.4;
    ctx.stroke();
  }

  // Midpoint label pill
  const label = connector.label?.trim().slice(0, 32);
  if (label) {
    ctx.font = `500 11px ${SYSTEM_SANS_FONT}`;
    const textW = ctx.measureText(label).width;
    const pillW = Math.max(40, textW + 18);
    const pillH = 22;
    roundedRectPath(ctx, mid.x - pillW * 0.5, mid.y - pillH * 0.5, pillW, pillH, 11);
    ctx.fillStyle = darkAppearance ? 'rgba(28, 30, 34, 0.92)' : 'rgba(255, 255, 255, 0.94)';
    ctx.fill();
    ctx.strokeStyle = hexToRgba(color, 0.45);
    ctx.lineWidth = 1;
    ctx.stroke();

    ctx.fillStyle = color;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(label, mid.x, mid.y + 0.5);
  }

  ctx.restore();
}

function drawInkStrokeOnCanvas(
  ctx: CanvasRenderingContext2D,
  stroke: InkStroke,
  offsetX: number,
  offsetY: number,
): void {
  if (stroke.points.length < 2) return;
  const pts = stroke.points.map((p) => ({ x: p.x + offsetX, y: p.y + offsetY }));

  ctx.save();
  ctx.strokeStyle = safeHex(stroke.colorHex, '#D95D48');
  ctx.globalAlpha = Math.max(0.05, Math.min(1, stroke.opacity ?? 0.92));
  ctx.lineWidth = Math.max(1, stroke.lineWidth || 3.5);
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';

  ctx.beginPath();
  ctx.moveTo(pts[0].x, pts[0].y);
  if (pts.length === 2) {
    ctx.lineTo(pts[1].x, pts[1].y);
  } else {
    for (let i = 1; i < pts.length - 1; i++) {
      const mx = (pts[i].x + pts[i + 1].x) * 0.5;
      const my = (pts[i].y + pts[i + 1].y) * 0.5;
      ctx.quadraticCurveTo(pts[i].x, pts[i].y, mx, my);
    }
    const last = pts[pts.length - 1];
    ctx.lineTo(last.x, last.y);
  }
  ctx.stroke();
  ctx.restore();
}

// MARK: - Browser-Native High-DPI Moodboard PNG / JPEG Exporter

export async function exportMoodboardImageInBrowser(
  params: ClientMoodboardImageExportParams,
): Promise<ClientMoodboardImageExportResult> {
  const { document, assetsByID, format = 'png', containerWidth = 1120, onProgress } = params;

  const baseOpts = createDefaultMoodboardExportOptions(params.options ?? {});
  const bgMode: ExportBackgroundMode =
    params.backgroundMode ?? (baseOpts.darkAppearance ? 'dark' : 'light');
  const darkAppearance = bgMode === 'dark';
  const isTransparent = bgMode === 'transparent' && format === 'png';
  const requestedScale = Math.max(0.5, Math.min(3, baseOpts.scale || 2));
  const pad = Math.max(0, baseOpts.padding ?? 40);

  const resolvedFrames = resolveDocumentFrames(document, assetsByID, containerWidth);

  // Tight bounding box across all rotated node corners + ink strokes
  let minX = Number.POSITIVE_INFINITY;
  let minY = Number.POSITIVE_INFINITY;
  let maxX = Number.NEGATIVE_INFINITY;
  let maxY = Number.NEGATIVE_INFINITY;

  for (const node of document.nodes) {
    const r = resolvedFrames[node.id];
    if (!r || r.width <= 0 || r.height <= 0) continue;
    const center = { x: r.x + r.width * 0.5, y: r.y + r.height * 0.5 };
    const corners: BoardPoint[] = [
      { x: r.x, y: r.y },
      { x: r.x + r.width, y: r.y },
      { x: r.x, y: r.y + r.height },
      { x: r.x + r.width, y: r.y + r.height },
    ];
    for (const corner of corners) {
      const p = rotatePoint(corner, center, node.rotationDegrees);
      minX = Math.min(minX, p.x);
      minY = Math.min(minY, p.y);
      maxX = Math.max(maxX, p.x);
      maxY = Math.max(maxY, p.y);
    }
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

  const edgeCapScale = MAX_CANVAS_EDGE / Math.max(canvasW, canvasH);
  const areaCapScale = Math.sqrt(MAX_CANVAS_AREA / (canvasW * canvasH));
  const effectiveScale = Math.min(requestedScale, edgeCapScale, areaCapScale);
  const pixelW = Math.max(1, Math.round(canvasW * effectiveScale));
  const pixelH = Math.max(1, Math.round(canvasH * effectiveScale));

  const offsetX = pad - minX;
  const offsetY = pad + headerHeight - minY;

  // Preload images for all unique referenced assets
  const assetNodes = document.nodes.filter(
    (n): n is BoardNode & { kind: Extract<BoardNode['kind'], { type: 'assetRef' }> } =>
      n.kind.type === 'assetRef',
  );
  const uniqueAssetIDs = Array.from(new Set(assetNodes.map((n) => n.kind.assetID)));
  const decodedImages = new Map<UUID, DecodedImage>();
  const totalSteps = uniqueAssetIDs.length + 2;
  let completedSteps = 0;

  onProgress?.({ stage: '正在加载画布素材…', completed: 0, total: totalSteps });

  const loadAssetForCanvas = async (assetID: UUID): Promise<DecodedImage | null> => {
    const asset = lookupAsset(assetsByID, assetID);
    const isRaster = !asset || asset.mediaKind === 'image' || asset.mediaKind === 'animatedImage';

    const candidateURLs: string[] = isRaster
      ? [
          originalMediaURL(assetID, { cachedOnly: true }),
          thumbnailURL(assetID, 'preview1400'),
          thumbnailURL(assetID, 'grid520'),
        ]
      : [thumbnailURL(assetID, 'preview1400'), thumbnailURL(assetID, 'grid520')];

    for (const url of candidateURLs) {
      const fetched = await fetchAuthenticatedBytes(url);
      if (!fetched) continue;
      // Avoid decoding massive originals during PNG preview when preview1400 exists
      if (fetched.bytes.byteLength > 28 * 1024 * 1024 && url !== candidateURLs[candidateURLs.length - 1]) {
        continue;
      }
      const decoded = await decodeImageBytes(fetched.bytes, fetched.contentType || asset?.mimeType);
      if (decoded) return decoded;
    }
    return null;
  };

  try {
    // Load with bounded concurrency (4)
    let cursor = 0;
    const workerCount = Math.min(4, Math.max(1, uniqueAssetIDs.length));
    await Promise.all(
      Array.from({ length: workerCount }, async () => {
        while (cursor < uniqueAssetIDs.length) {
          const assetID = uniqueAssetIDs[cursor++];
          const decoded = await loadAssetForCanvas(assetID);
          if (decoded) decodedImages.set(assetID, decoded);
          completedSteps++;
          onProgress?.({
            stage: '正在加载画布素材…',
            completed: completedSteps,
            total: totalSteps,
          });
        }
      }),
    );

    onProgress?.({ stage: '正在渲染高清画布…', completed: completedSteps, total: totalSteps });

    const canvas = window.document.createElement('canvas');
    canvas.width = pixelW;
    canvas.height = pixelH;
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      throw new Error('导出失败，请刷新后重试');
    }

    ctx.scale(effectiveScale, effectiveScale);
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';

    // Background fill
    if (!isTransparent) {
      ctx.fillStyle = darkAppearance ? '#141517' : '#F6F6F5';
      ctx.fillRect(0, 0, canvasW, canvasH);
    }

    const inkPrimary = darkAppearance ? 'rgba(255,255,255,0.92)' : 'rgba(20,22,26,0.88)';
    const inkSecondary = darkAppearance ? 'rgba(255,255,255,0.56)' : 'rgba(20,22,26,0.50)';

    // Header: Title, Subtitle & optional top Board Palette Strip
    ctx.save();
    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';
    ctx.fillStyle = inkPrimary;
    ctx.font = `600 20px ${SYSTEM_SANS_FONT}`;
    ctx.fillText(document.title || 'Charkle 情绪板', pad, pad * 0.65 + 20);

    if (document.subtitle.trim()) {
      ctx.fillStyle = inkSecondary;
      ctx.font = `400 12px ${SYSTEM_SANS_FONT}`;
      ctx.fillText(document.subtitle.trim().slice(0, 120), pad, pad * 0.65 + 42);
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
        roundedRectPath(ctx, sx, sy, swW, swH, 6);
        ctx.fillStyle = hex;
        ctx.fill();
        ctx.strokeStyle = darkAppearance ? 'rgba(255,255,255,0.16)' : 'rgba(0,0,0,0.12)';
        ctx.lineWidth = 0.75;
        ctx.stroke();
        sx += swW + gap;
      }
    }
    ctx.restore();

    const orderedNodes = resolveOrderedNodes(document);
    const nodeByID = new Map(document.nodes.map((n) => [n.id, n]));

    // Draw nodes in exact z-order (groupFrames behind, then sorted zIndex/editorialOrder)
    for (const node of orderedNodes) {
      const baseRect = resolvedFrames[node.id];
      if (!baseRect || baseRect.width <= 0 || baseRect.height <= 0) continue;

      const x = baseRect.x + offsetX;
      const y = baseRect.y + offsetY;
      const w = baseRect.width;
      const h = baseRect.height;
      const cx = x + w * 0.5;
      const cy = y + h * 0.5;

      ctx.save();
      ctx.translate(cx, cy);
      if (Math.abs(node.rotationDegrees) > 0.05) {
        ctx.rotate((node.rotationDegrees * Math.PI) / 180);
      }

      if (node.kind.type === 'groupFrame') {
        const tint = groupTintHex(node.kind.tint);
        roundedRectPath(ctx, -w * 0.5, -h * 0.5, w, h, 16);
        ctx.fillStyle = hexToRgba(tint, darkAppearance ? 0.14 : 0.09);
        ctx.fill();
        ctx.strokeStyle = hexToRgba(tint, 0.45);
        ctx.lineWidth = 1.5;
        ctx.setLineDash([6, 4]);
        ctx.stroke();
        ctx.setLineDash([]);

        // Accent dot + title
        ctx.beginPath();
        ctx.arc(-w * 0.5 + 16, -h * 0.5 + 18, 4, 0, Math.PI * 2);
        ctx.fillStyle = tint;
        ctx.fill();

        ctx.fillStyle = inkPrimary;
        ctx.font = `600 13px ${SYSTEM_SANS_FONT}`;
        ctx.textAlign = 'left';
        ctx.textBaseline = 'middle';
        ctx.fillText(node.kind.title || '分组区域', -w * 0.5 + 28, -h * 0.5 + 18, Math.max(40, w - 40));
      } else if (node.kind.type === 'assetRef') {
        const asset = lookupAsset(assetsByID, node.kind.assetID);
        const decoded = decodedImages.get(node.kind.assetID);

        roundedRectPath(ctx, -w * 0.5, -h * 0.5, w, h, 12);
        ctx.save();
        ctx.clip();

        if (decoded) {
          ctx.scale(node.flipHorizontal ? -1 : 1, node.flipVertical ? -1 : 1);

          let sx = 0;
          let sy = 0;
          let sw = decoded.width;
          let sh = decoded.height;

          const crop = node.kind.crop;
          if (
            crop &&
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
            sx = c.x * decoded.width;
            sy = c.y * decoded.height;
            sw = Math.max(1, c.width * decoded.width);
            sh = Math.max(1, c.height * decoded.height);
          }

          // Aspect-fill (cover) inside node frame without distortion
          const srcAspect = sw / Math.max(1, sh);
          const dstAspect = w / Math.max(1, h);
          if (srcAspect > dstAspect) {
            const coverW = sh * dstAspect;
            sx += (sw - coverW) * 0.5;
            sw = coverW;
          } else {
            const coverH = sw / dstAspect;
            sy += (sh - coverH) * 0.5;
            sh = coverH;
          }

          ctx.drawImage(decoded.source, sx, sy, sw, sh, -w * 0.5, -h * 0.5, w, h);
        } else {
          const fallbackHex = safeHex(
            asset?.dominantColors[0]?.hex,
            darkAppearance ? '#2B2F36' : '#DFDDD7',
          );
          ctx.fillStyle = fallbackHex;
          ctx.fillRect(-w * 0.5, -h * 0.5, w, h);
          if (asset?.title) {
            ctx.fillStyle = isLightHex(fallbackHex)
              ? 'rgba(20,20,24,0.78)'
              : 'rgba(255,255,255,0.88)';
            ctx.font = `500 12px ${SYSTEM_SANS_FONT}`;
            ctx.textAlign = 'left';
            ctx.textBaseline = 'top';
            ctx.fillText(asset.title.slice(0, 28), -w * 0.5 + 12, -h * 0.5 + 14, Math.max(24, w - 24));
          }
        }
        ctx.restore();

        // Crisp card hairline border
        roundedRectPath(ctx, -w * 0.5, -h * 0.5, w, h, 12);
        ctx.strokeStyle = darkAppearance ? 'rgba(255,255,255,0.10)' : 'rgba(0,0,0,0.08)';
        ctx.lineWidth = 1;
        ctx.stroke();
      } else if (node.kind.type === 'note') {
        const colors = noteColors(node.kind.style);
        const fontSize = Math.max(11, node.kind.fontSize || 14);

        ctx.save();
        ctx.shadowColor = darkAppearance ? 'rgba(0,0,0,0.28)' : 'rgba(0,0,0,0.06)';
        ctx.shadowBlur = 10;
        ctx.shadowOffsetY = 3;
        roundedRectPath(ctx, -w * 0.5, -h * 0.5, w, h, 12);
        ctx.fillStyle = colors.bg;
        ctx.fill();
        ctx.restore();

        roundedRectPath(ctx, -w * 0.5, -h * 0.5, w, h, 12);
        ctx.strokeStyle = colors.border;
        ctx.lineWidth = 1;
        ctx.stroke();

        ctx.save();
        roundedRectPath(ctx, -w * 0.5, -h * 0.5, w, h, 12);
        ctx.clip();

        const padX = 14;
        const innerW = Math.max(32, w - padX * 2);
        let cursorY = -h * 0.5 + 14;
        ctx.textAlign = 'left';
        ctx.textBaseline = 'top';

        const trimmedTitle = node.kind.title?.trim();
        if (trimmedTitle) {
          const titleFontSize = Math.max(13, fontSize);
          ctx.font = `600 ${titleFontSize}px ${SYSTEM_SANS_FONT}`;
          ctx.fillStyle = colors.fg;
          ctx.fillText(trimmedTitle.slice(0, 48), -w * 0.5 + padX, cursorY, innerW);
          cursorY += titleFontSize + 10;

          ctx.fillStyle = hexToRgba(colors.fg, 0.12);
          ctx.fillRect(-w * 0.5 + padX, cursorY - 4, innerW, 1);
          cursorY += 4;
        }

        const bodyFont = Math.max(11, fontSize - 1);
        const lineHeight = Math.round(bodyFont * 1.48);
        const availH = h * 0.5 - cursorY - 10;
        const maxLines = Math.max(1, Math.floor(availH / lineHeight));
        ctx.font = `400 ${bodyFont}px ${SYSTEM_SANS_FONT}`;
        ctx.fillStyle = hexToRgba(colors.fg, 0.9);
        const lines = wrapTextToWidth(ctx, node.kind.text || '', innerW, maxLines);
        for (const line of lines) {
          ctx.fillText(line, -w * 0.5 + padX, cursorY);
          cursorY += lineHeight;
        }

        ctx.restore();
      } else if (node.kind.type === 'paletteStrip') {
        const activeColors =
          node.kind.autoSyncWithBoard && document.extractedPalette.length > 0
            ? document.extractedPalette
            : node.kind.colors;
        const list = activeColors.length > 0 ? activeColors : [labFromHex('#808080')];
        const segW = w / list.length;

        ctx.save();
        roundedRectPath(ctx, -w * 0.5, -h * 0.5, w, h, 12);
        ctx.clip();

        list.forEach((c, idx) => {
          const hex = safeHex(c.hex, '#808080');
          const sx = -w * 0.5 + idx * segW;
          ctx.fillStyle = hex;
          ctx.fillRect(sx, -h * 0.5, segW + 0.8, h);

          if (segW >= 48) {
            ctx.fillStyle = isLightHex(hex) ? 'rgba(24,24,27,0.84)' : 'rgba(248,248,250,0.92)';
            ctx.font = `600 10px ${SYSTEM_MONO_FONT}`;
            ctx.textAlign = 'left';
            ctx.textBaseline = 'bottom';
            ctx.fillText(hex, sx + 8, h * 0.5 - 8);
          }
        });
        ctx.restore();

        roundedRectPath(ctx, -w * 0.5, -h * 0.5, w, h, 12);
        ctx.strokeStyle = darkAppearance ? 'rgba(255,255,255,0.14)' : 'rgba(0,0,0,0.12)';
        ctx.lineWidth = 1;
        ctx.stroke();
      }

      ctx.restore();
    }

    // Annotations layer (connectors + freehand ink strokes)
    if (baseOpts.includeAnnotations) {
      for (const connector of document.connectors) {
        const fromNode = nodeByID.get(connector.fromNodeID);
        const toNode = nodeByID.get(connector.toNodeID);
        const fromBase = resolvedFrames[connector.fromNodeID];
        const toBase = resolvedFrames[connector.toNodeID];
        if (!fromNode || !toNode || !fromBase || !toBase) continue;

        drawConnectorOnCanvas(
          ctx,
          connector,
          fromNode,
          { x: fromBase.x + offsetX, y: fromBase.y + offsetY, width: fromBase.width, height: fromBase.height },
          toNode,
          { x: toBase.x + offsetX, y: toBase.y + offsetY, width: toBase.width, height: toBase.height },
          darkAppearance,
        );
      }

      for (const stroke of document.inkStrokes) {
        drawInkStrokeOnCanvas(ctx, stroke, offsetX, offsetY);
      }
    }

    onProgress?.({ stage: '正在编码图像…', completed: totalSteps - 1, total: totalSteps });

    const mimeType = format === 'jpeg' ? 'image/jpeg' : 'image/png';
    const blob = await canvasToBlob(canvas, mimeType, format === 'jpeg' ? 0.92 : undefined);

    onProgress?.({ stage: '导出完成', completed: totalSteps, total: totalSteps });

    const ext = format === 'jpeg' ? 'jpg' : 'png';
    const scaleTag = Number.isInteger(requestedScale) ? `${requestedScale}x` : `${requestedScale.toFixed(1)}x`;
    const filename = `${sanitizeFilenameSlug(document.title)}-${scaleTag}.${ext}`;

    return { blob, filename, width: pixelW, height: pixelH };
  } finally {
    for (const img of decodedImages.values()) {
      img.cleanup();
    }
  }
}

// MARK: - Browser-Native Offline Lossless `.charkleboard` Figma / FigJam Exporter

function geometryObj(
  rect: BoardRect,
  angle: number,
  flipX: boolean,
  flipY: boolean,
): FigmaBridgeObjectGeometry {
  return {
    x: rect.x,
    y: rect.y,
    width: rect.width,
    height: rect.height,
    angle,
    flipX,
    flipY,
  };
}

async function writeBrowserLosslessTiles(
  source: CanvasImageSource,
  cropX: number,
  cropY: number,
  cropW: number,
  cropH: number,
  zip: JSZip,
  prefix: string,
): Promise<FigmaBridgeTile[]> {
  const tiles: FigmaBridgeTile[] = [];
  const safePrefix = sanitizeSafeToken(prefix);

  let row = 0;
  for (let y = 0; y < cropH; y += TILE_LIMIT, row++) {
    let col = 0;
    for (let x = 0; x < cropW; x += TILE_LIMIT, col++) {
      const w = Math.min(TILE_LIMIT, cropW - x);
      const h = Math.min(TILE_LIMIT, cropH - y);

      const tileCanvas = window.document.createElement('canvas');
      tileCanvas.width = w;
      tileCanvas.height = h;
      const tCtx = tileCanvas.getContext('2d');
      if (!tCtx) {
        throw new Error('导出图层失败，请刷新后重试');
      }
      tCtx.clearRect(0, 0, w, h);
      tCtx.drawImage(source, cropX + x, cropY + y, w, h, 0, 0, w, h);

      const tileBlob = await canvasToBlob(tileCanvas, 'image/png');
      const tileBytes = new Uint8Array(await tileBlob.arrayBuffer());
      const tileHash = await sha256Hex(tileBytes);

      const relPath = `tiles/${safePrefix}_r${row}_c${col}.png`;
      zip.file(relPath, tileBytes, { compression: 'STORE' });
      tiles.push({
        file: relPath,
        x,
        y,
        width: w,
        height: h,
        sha256: tileHash,
      });
    }
  }

  return tiles;
}

/**
 * Pure browser port of `FigmaBridgeExporter` producing 100% lossless `.charkleboard` v1
 * packages verified against `figma-plugin/code.js` (including raw GIF archival for FigJam
 * `figma.createGif`, baked non-destructive crops, `<= 4096×4096` lossless PNG tiles, and
 * per-file / per-tile SHA-256 digests).
 */
export async function exportFigmaBridgeInBrowser(
  params: ClientFigmaBridgeExportParams,
): Promise<ClientFigmaBridgeExportResult> {
  const { document, assetsByID, containerWidth = 1120, onProgress } = params;
  const options = createDefaultMoodboardExportOptions(params.options ?? {});

  const resolvedFrames = resolveDocumentFrames(document, assetsByID, containerWidth);
  const orderedNodes = resolveOrderedNodes(document);

  const zip = new JSZip();
  const objects: FigmaBridgeObject[] = [];
  const warnings: Array<{ id: string; name: string; issues: string[] }> = [];
  const originals: FigmaBridgeBoardManifest['originals'] = [];
  const archivedOriginals = new Map<UUID, { file: string; sha256: string; isGIF: boolean; bytes: Uint8Array; contentType: string; fromOriginal: boolean }>();
  const cachedTilePayloads = new Map<string, NonNullable<FigmaBridgeObject['image']>>();

  let imageCount = 0;
  let noteCount = 0;
  let groupCount = 0;
  let paletteCount = 0;

  const totalSteps = orderedNodes.length + 2;
  let completedSteps = 0;
  onProgress?.({ stage: '正在准备迁移包…', completed: 0, total: totalSteps });

  // Optional top Board Palette Strip positioned cleanly above content bounds
  if (options.includePaletteStrip && document.extractedPalette.length > 0) {
    const frameValues = Object.values(resolvedFrames).filter((r) => r.width > 0 && r.height > 0);
    const minX = frameValues.length > 0 ? Math.min(...frameValues.map((r) => r.x)) : 0;
    const minY = frameValues.length > 0 ? Math.min(...frameValues.map((r) => r.y)) : 0;
    const maxX =
      frameValues.length > 0 ? Math.max(...frameValues.map((r) => r.x + r.width)) : 800;
    const stripW = Math.max(320, Math.min(560, maxX - minX));
    const stripH = 54;
    const swatches = document.extractedPalette.slice(0, 7).map((sw) => {
      const hex = safeHex(sw.hex, '#808080');
      return { hex, isLight: isLightHex(hex) };
    });
    objects.push({
      id: 'board-palette-header',
      kind: 'paletteStrip',
      name: '板内色卡',
      locked: false,
      geometry: geometryObj({ x: minX, y: minY - stripH - 24, width: stripW, height: stripH }, 0, false, false),
      palette: { swatches },
      warnings: [],
    });
    paletteCount += 1;
  }

  for (const node of orderedNodes) {
    completedSteps++;
    const frame = resolvedFrames[node.id];
    if (!frame || frame.width <= 0 || frame.height <= 0) continue;

    const geom = geometryObj(frame, node.rotationDegrees, node.flipHorizontal, node.flipVertical);

    if (node.kind.type === 'assetRef') {
      const assetID = node.kind.assetID;
      const asset = lookupAsset(assetsByID, assetID);
      const displayName = asset?.title || '素材';
      const itemWarnings: string[] = [];

      onProgress?.({
        stage: `正在处理图层「${displayName.slice(0, 18)}」…`,
        completed: completedSteps,
        total: totalSteps,
      });

      let archivedInfo = archivedOriginals.get(assetID);
      if (!archivedInfo) {
        const originalFetch = await fetchAuthenticatedBytes(originalMediaURL(assetID));
        let fallbackFetch: { bytes: Uint8Array; contentType: string } | null = null;
        if (!originalFetch) {
          fallbackFetch =
            (await fetchAuthenticatedBytes(thumbnailURL(assetID, 'preview1400'))) ??
            (await fetchAuthenticatedBytes(thumbnailURL(assetID, 'grid520')));
        }

        const picked = originalFetch ?? fallbackFetch;
        if (!picked || picked.bytes.byteLength === 0) {
          itemWarnings.push('素材文件缺失，无法导出画面');
          warnings.push({ id: node.id, name: displayName, issues: itemWarnings });
          objects.push({
            id: node.id,
            kind: 'unsupported',
            name: displayName,
            locked: node.isLocked,
            geometry: geom,
            warnings: itemWarnings,
          });
          continue;
        }

        const fromOriginal = Boolean(originalFetch);
        const rawExt = extractExtension(asset?.fileName);
        const safeExt =
          rawExt ||
          (picked.contentType.includes('gif')
            ? 'gif'
            : picked.contentType.includes('png')
              ? 'png'
              : picked.contentType.includes('webp')
                ? 'webp'
                : picked.contentType.includes('jpeg') || picked.contentType.includes('jpg')
                  ? 'jpg'
                  : fromOriginal
                    ? 'bin'
                    : 'jpg');
        const safeAssetID = sanitizeSafeToken(assetID);
        const fileName = `${safeAssetID}.${safeExt}`;
        const relPath = `originals/${fileName}`;
        zip.file(relPath, picked.bytes, { compression: 'STORE' });
        const digest = await sha256Hex(picked.bytes);
        const isGIF =
          safeExt === 'gif' ||
          picked.contentType.toLowerCase().includes('image/gif') ||
          asset?.mediaKind === 'animatedImage';

        originals.push({
          id: assetID,
          name: asset?.fileName || fileName,
          file: relPath,
          sha256: digest,
          bytes: picked.bytes.byteLength,
        });

        archivedInfo = {
          file: relPath,
          sha256: digest,
          isGIF,
          bytes: picked.bytes,
          contentType: picked.contentType || asset?.mimeType || '',
          fromOriginal,
        };
        archivedOriginals.set(assetID, archivedInfo);
      }

      if (!archivedInfo.fromOriginal) {
        itemWarnings.push('原文件未缓存在本地，已使用高清预览图导出');
      }

      // Decode upright raster (or fallback to preview thumbnail for non-image media)
      let decoded = await decodeImageBytes(archivedInfo.bytes, archivedInfo.contentType);
      let isAnimatedGIF = archivedInfo.isGIF && countGifFrames(archivedInfo.bytes) > 1;

      if (!decoded) {
        const thumbFetch =
          (await fetchAuthenticatedBytes(thumbnailURL(assetID, 'preview1400'))) ??
          (await fetchAuthenticatedBytes(thumbnailURL(assetID, 'grid520')));
        if (thumbFetch) {
          decoded = await decodeImageBytes(thumbFetch.bytes, thumbFetch.contentType);
          const label = asset ? mediaKindLocalizedLabel(asset.mediaKind) : '附件';
          itemWarnings.push(
            `${label}素材已导出预览图，原文件已保留在导出包中`,
          );
          isAnimatedGIF = false;
        }
      }

      if (!decoded) {
        itemWarnings.push('无法生成该素材预览，原文件已保留在导出包中');
        warnings.push({ id: node.id, name: displayName, issues: itemWarnings });
        objects.push({
          id: node.id,
          kind: 'unsupported',
          name: displayName,
          locked: node.isLocked,
          geometry: geom,
          warnings: itemWarnings,
        });
        continue;
      }

      try {
        let rx = 0;
        let ry = 0;
        let rw = decoded.width;
        let rh = decoded.height;
        let cropKey = 'full';

        const crop = node.kind.crop;
        if (
          crop &&
          crop.width > 0.05 &&
          crop.height > 0.05 &&
          !(
            crop.x === FULL_CROP_RECT.x &&
            crop.y === FULL_CROP_RECT.y &&
            crop.width === FULL_CROP_RECT.width &&
            crop.height === FULL_CROP_RECT.height
          )
        ) {
          const c = clampCropRect(crop);
          rx = Math.max(0, Math.min(decoded.width - 1, Math.floor(c.x * decoded.width)));
          ry = Math.max(0, Math.min(decoded.height - 1, Math.floor(c.y * decoded.height)));
          rw = Math.max(1, Math.min(decoded.width - rx, Math.round(c.width * decoded.width)));
          rh = Math.max(1, Math.min(decoded.height - ry, Math.round(c.height * decoded.height)));
          cropKey = `${c.x.toFixed(3)}-${c.y.toFixed(3)}-${c.width.toFixed(3)}-${c.height.toFixed(3)}`;
        }

        const tileCacheKey = `${assetID}-${cropKey}`;
        let imagePayload = cachedTilePayloads.get(tileCacheKey);
        if (!imagePayload) {
          const hashPrefix =
            cropKey === 'full'
              ? archivedInfo.sha256.slice(0, 12)
              : `${archivedInfo.sha256.slice(0, 10)}_c${await shortStableHash(cropKey)}`;
          const tiles = await writeBrowserLosslessTiles(
            decoded.source,
            rx,
            ry,
            rw,
            rh,
            zip,
            hashPrefix,
          );
          const animated =
            isAnimatedGIF &&
            cropKey === 'full' &&
            archivedInfo.file.toLowerCase().endsWith('.gif');
          imagePayload = {
            pixelWidth: rw,
            pixelHeight: rh,
            tiles,
            animated,
          };
          if (animated) {
            imagePayload.animation = {
              file: archivedInfo.file,
              sha256: archivedInfo.sha256,
            };
          }
          cachedTilePayloads.set(tileCacheKey, imagePayload);
        }

        if (imagePayload.animation) {
          itemWarnings.push('动画 GIF 在 Figma Design 中以静态首帧导入，原始 GIF 已归档');
        }

        if (itemWarnings.length > 0) {
          warnings.push({ id: node.id, name: displayName, issues: itemWarnings });
        }

        objects.push({
          id: node.id,
          kind: 'image',
          name: displayName,
          cornerRadius: 12,
          locked: node.isLocked,
          geometry: geom,
          image: imagePayload,
          warnings: itemWarnings,
        });
        imageCount += 1;
      } finally {
        decoded.cleanup();
      }
    } else if (node.kind.type === 'note') {
      const hex = noteColors(node.kind.style);
      const trimmedTitle = node.kind.title?.trim() ?? '';
      const noteName = trimmedTitle || node.kind.text.slice(0, 24) || '灵感便签';
      objects.push({
        id: node.id,
        kind: 'note',
        name: noteName,
        locked: node.isLocked,
        geometry: geom,
        note: {
          title: node.kind.title ?? '',
          text: node.kind.text,
          style: node.kind.style,
          fontSize: node.kind.fontSize,
          backgroundHex: hex.bg,
          foregroundHex: hex.fg,
          borderHex: hex.border,
        },
        warnings: [],
      });
      noteCount += 1;
    } else if (node.kind.type === 'groupFrame') {
      objects.push({
        id: node.id,
        kind: 'groupFrame',
        name: node.kind.title || '分组区域',
        locked: node.isLocked,
        geometry: geom,
        group: {
          title: node.kind.title,
          tint: node.kind.tint,
          accentHex: groupTintHex(node.kind.tint),
        },
        warnings: [],
      });
      groupCount += 1;
    } else if (node.kind.type === 'paletteStrip') {
      const activeColors =
        node.kind.autoSyncWithBoard && document.extractedPalette.length > 0
          ? document.extractedPalette
          : node.kind.colors;
      const sourceColors = activeColors.length > 0 ? activeColors : [labFromHex('#8B95A1')];
      const swatches = sourceColors.map((sw) => {
        const hex = safeHex(sw.hex, '#8B95A1');
        return { hex, isLight: isLightHex(hex) };
      });
      objects.push({
        id: node.id,
        kind: 'paletteStrip',
        name: '色卡条',
        locked: node.isLocked,
        geometry: geom,
        palette: { swatches },
        warnings: [],
      });
      paletteCount += 1;
    }
  }

  if (objects.length === 0) {
    throw new Error('当前情绪板里没有可导出的对象。');
  }

  const connectorJSONs: FigmaBridgeBoardManifest['connectors'] = [];
  const strokeJSONs: FigmaBridgeBoardManifest['inkStrokes'] = [];

  if (options.includeAnnotations) {
    const exportedIDs = new Set(objects.map((o) => o.id));
    for (const conn of document.connectors) {
      if (!exportedIDs.has(conn.fromNodeID) || !exportedIDs.has(conn.toNodeID)) continue;
      connectorJSONs.push({
        id: conn.id,
        fromNodeID: conn.fromNodeID,
        fromAnchor: conn.fromAnchor,
        toNodeID: conn.toNodeID,
        toAnchor: conn.toAnchor,
        style: conn.style,
        colorHex: conn.colorHex,
        dashed: conn.dashed,
        label: conn.label ?? '',
      });
    }
    for (const stroke of document.inkStrokes) {
      if (stroke.points.length < 2) continue;
      strokeJSONs.push({
        id: stroke.id,
        points: stroke.points.map((pt) => ({ x: pt.x, y: pt.y })),
        colorHex: stroke.colorHex,
        lineWidth: stroke.lineWidth,
        opacity: stroke.opacity,
      });
    }
  }

  const report: FigmaBridgeReport = {
    objectCount: objects.length,
    imageCount,
    noteCount,
    groupCount,
    paletteCount,
    connectorCount: connectorJSONs.length,
    strokeCount: strokeJSONs.length,
    reviewCount: warnings.length,
    warnings,
  };

  const manifest: FigmaBridgeBoardManifest = {
    format: 'charkle-figma-bridge',
    version: 1,
    boardId: document.id,
    name: document.title,
    subtitle: document.subtitle,
    mode: document.mode.type === 'autoEditorial' ? 'autoEditorial' : 'freeform',
    darkAppearance: options.darkAppearance,
    exportedAt: new Date().toISOString(),
    sourceOS: 'Charkle Web',
    objects,
    connectors: connectorJSONs,
    inkStrokes: strokeJSONs,
    originals,
    report,
  };

  onProgress?.({ stage: '正在打包 .charkleboard…', completed: totalSteps - 1, total: totalSteps });

  zip.file('board.json', JSON.stringify(manifest, null, 2), { compression: 'DEFLATE' });
  zip.file('migration-report.json', JSON.stringify(report, null, 2), { compression: 'DEFLATE' });

  const blob = await zip.generateAsync({
    type: 'blob',
    compression: 'DEFLATE',
    compressionOptions: { level: 6 },
  });

  onProgress?.({ stage: '打包完成', completed: totalSteps, total: totalSteps });

  const filename = `${sanitizeFilenameSlug(document.title)}.charkleboard`;
  return { blob, filename, manifest, report };
}
