//! Deterministic TypeScript mirror of `crates/charkle-core/src/layout/editorial.rs`
//! and macOS `EditorialLayoutSolver.swift` enabling 60/120 FPS Auto Editorial drag-reorder,
//! Smart Auto-Layout GroupFrame reflow, connector geometry, and harmonious palette extraction.

import {
  isAutoEditorialMode,
  type AssetRecord,
  type AutoLayoutConfig,
  type BoardConnector,
  type BoardNode,
  type BoardPoint,
  type BoardRect,
  type ConnectorAnchor,
  type EditorialLayoutResult,
  type EditorialStyle,
  type GroupTint,
  type InkStrokePoint,
  type LabColor,
  type MoodboardDocument,
  type NormalizedCropRect,
  type NoteStyle,
} from '../../types/domain';

export interface NoteStyleTheme {
  label: string;
  bg: string;
  fg: string;
  border: string;
}

export interface GroupTintTheme {
  label: string;
  accent: string;
  bgLight: string;
  bgDark: string;
  headerLight: string;
  headerDark: string;
}

export const NOTE_STYLE_PALETTE: Record<NoteStyle, NoteStyleTheme> = {
  paper: { label: '纸白', bg: '#FFFFFF', fg: '#1D1F23', border: 'rgba(0,0,0,0.09)' },
  ink: { label: '墨黑', bg: '#1D1F24', fg: '#F1F2F4', border: 'rgba(255,255,255,0.14)' },
  warm: { label: '暖沙', bg: '#F7F0E4', fg: '#392F22', border: 'rgba(201,183,156,0.45)' },
  sage: { label: '鼠尾草', bg: '#E8F0EA', fg: '#203227', border: 'rgba(154,181,163,0.45)' },
  slate: { label: '岩灰', bg: '#E9EEF3', fg: '#1F2B36', border: 'rgba(158,176,194,0.45)' },
};

export const GROUP_TINT_PALETTE: Record<GroupTint, GroupTintTheme> = {
  neutral: {
    label: '中性灰',
    accent: '#7D838B',
    bgLight: 'rgba(125,131,139,0.03)',
    bgDark: 'rgba(125,131,139,0.06)',
    headerLight: 'rgba(125,131,139,0.08)',
    headerDark: 'rgba(125,131,139,0.14)',
  },
  sand: {
    label: '暖沙',
    accent: '#B5956B',
    bgLight: 'rgba(181,149,107,0.035)',
    bgDark: 'rgba(181,149,107,0.065)',
    headerLight: 'rgba(181,149,107,0.08)',
    headerDark: 'rgba(181,149,107,0.14)',
  },
  sage: {
    label: '青苔',
    accent: '#6B8E76',
    bgLight: 'rgba(107,142,118,0.035)',
    bgDark: 'rgba(107,142,118,0.065)',
    headerLight: 'rgba(107,142,118,0.08)',
    headerDark: 'rgba(107,142,118,0.14)',
  },
  slate: {
    label: '板岩',
    accent: '#627A94',
    bgLight: 'rgba(98,122,148,0.035)',
    bgDark: 'rgba(98,122,148,0.065)',
    headerLight: 'rgba(98,122,148,0.08)',
    headerDark: 'rgba(98,122,148,0.14)',
  },
  terracotta: {
    label: '陶土',
    accent: '#BA6B55',
    bgLight: 'rgba(186,107,85,0.035)',
    bgDark: 'rgba(186,107,85,0.065)',
    headerLight: 'rgba(186,107,85,0.08)',
    headerDark: 'rgba(186,107,85,0.14)',
  },
  ocean: {
    label: '深海',
    accent: '#4D7E97',
    bgLight: 'rgba(77,126,151,0.035)',
    bgDark: 'rgba(77,126,151,0.065)',
    headerLight: 'rgba(77,126,151,0.08)',
    headerDark: 'rgba(77,126,151,0.14)',
  },
};

export function getNoteStylePalette(style?: string | null): NoteStyleTheme {
  if (style && style in NOTE_STYLE_PALETTE) {
    return NOTE_STYLE_PALETTE[style as NoteStyle];
  }
  return NOTE_STYLE_PALETTE.paper;
}

export function getGroupTintPalette(tint?: string | null): GroupTintTheme {
  if (tint && tint in GROUP_TINT_PALETTE) {
    return GROUP_TINT_PALETTE[tint as GroupTint];
  }
  return GROUP_TINT_PALETTE.neutral;
}

export function isLightHex(hex: string): boolean {
  const cleaned = hex.trim().replace(/^#/, '');
  if (!/^[0-9a-fA-F]{6}$/.test(cleaned)) return false;
  const r = parseInt(cleaned.slice(0, 2), 16) / 255;
  const g = parseInt(cleaned.slice(2, 4), 16) / 255;
  const b = parseInt(cleaned.slice(4, 6), 16) / 255;
  return 0.299 * r + 0.587 * g + 0.114 * b > 0.62;
}

export function normalizeDegrees(degrees: number): number {
  if (!Number.isFinite(degrees)) return 0;
  let d = degrees % 360;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  if (Math.abs(d) < 0.05) d = 0;
  return d;
}

export function extractBoardPaletteFromAssets(
  assets: AssetRecord[],
  count = 6,
): LabColor[] {
  const bucket = new Map<string, { color: LabColor; weight: number }>();
  for (const asset of assets) {
    const dom = Array.isArray(asset.dominantColors) ? asset.dominantColors : [];
    for (const color of dom.slice(0, 2)) {
      if (!color?.hex) continue;
      const key = color.hex.toUpperCase();
      const prev = bucket.get(key);
      const add = Number.isFinite(color.proportion) ? Math.max(0.15, color.proportion) : 0.2;
      if (prev) {
        prev.weight += add;
      } else {
        bucket.set(key, {
          color: { ...color, hex: key },
          weight: add,
        });
      }
    }
  }
  const ranked = Array.from(bucket.values()).sort((a, b) => b.weight - a.weight);
  const distinct: LabColor[] = [];
  for (const entry of ranked) {
    const c = entry.color;
    const tooClose = distinct.some((d) => {
      const dl = (d.l ?? 50) - (c.l ?? 50);
      const da = (d.a ?? 0) - (c.a ?? 0);
      const db = (d.b ?? 0) - (c.b ?? 0);
      return Math.sqrt(dl * dl + da * da + db * db) < 14;
    });
    if (!tooClose) {
      distinct.push(c);
      if (distinct.length >= count) break;
    }
  }
  return distinct;
}

function resolvedAspectRatio(
  assetId: string,
  crop: NormalizedCropRect | null | undefined,
  assetsById: Map<string, AssetRecord>,
  style: EditorialStyle,
): number {
  const asset = assetsById.get(assetId);
  let ratio =
    asset && asset.pixelWidth > 0 && asset.pixelHeight > 0
      ? asset.pixelWidth / asset.pixelHeight
      : 1.25;
  if (
    crop &&
    Number.isFinite(crop.width) &&
    Number.isFinite(crop.height) &&
    crop.width > 0.05 &&
    crop.height > 0.05
  ) {
    ratio *= crop.width / crop.height;
  }
  if (!Number.isFinite(ratio)) ratio = 1.25;
  if (style === 'compact') return Math.max(0.8, Math.min(1.32, ratio));
  if (style === 'magazine') return Math.max(0.56, Math.min(2.15, ratio));
  return Math.max(0.64, Math.min(1.85, ratio));
}

function shortestColumnIndex(heights: number[]): number {
  if (heights.length === 0) return 0;
  let bestIdx = 0;
  let bestVal = heights[0];
  for (let i = 1; i < heights.length; i++) {
    if (heights[i] < bestVal - 1.0) {
      bestVal = heights[i];
      bestIdx = i;
    }
  }
  return bestIdx;
}

function bestTwoColumnSpanStart(heights: number[]): number | null {
  if (heights.length < 2) return null;
  let bestStart = 0;
  let bestMax = Math.max(heights[0], heights[1]);
  for (let i = 1; i < heights.length - 1; i++) {
    const pairMax = Math.max(heights[i], heights[i + 1]);
    if (pairMax < bestMax - 1.0) {
      bestMax = pairMax;
      bestStart = i;
    }
  }
  return bestStart;
}

export function solveEditorialLayout(
  nodes: BoardNode[],
  config: AutoLayoutConfig,
  containerWidth: number,
  assetsById: Map<string, AssetRecord>,
  padding = 28,
): EditorialLayoutResult {
  const safeNodes = Array.isArray(nodes) ? nodes : [];
  const safeContainerWidth =
    Number.isFinite(containerWidth) && containerWidth > 0 ? containerWidth : 1080;
  const safePadding = Number.isFinite(padding) ? Math.max(0, Math.min(240, padding)) : 28;
  const safeSpacing = Number.isFinite(config?.spacing)
    ? Math.max(0, Math.min(120, config.spacing))
    : 16;
  const style: EditorialStyle = config?.style ?? 'balanced';

  const effectivePadding =
    style === 'magazine'
      ? Math.max(36, safePadding + 10)
      : style === 'balanced'
        ? Math.max(22, safePadding)
        : Math.max(12, Math.min(safePadding, 14));

  const usableWidth = Math.max(320, safeContainerWidth - effectivePadding * 2);
  const styleSpacing =
    style === 'magazine'
      ? Math.max(26, safeSpacing + 10)
      : style === 'balanced'
        ? Math.max(15, safeSpacing)
        : 6;

  const cols =
    style === 'magazine'
      ? Math.max(2, Math.min(3, Math.trunc((usableWidth + styleSpacing) / 280)))
      : style === 'balanced'
        ? Math.max(3, Math.min(4, Math.trunc((usableWidth + styleSpacing) / 220)))
        : Math.max(5, Math.min(7, Math.trunc((usableWidth + styleSpacing) / 142)));

  const colWidth = (usableWidth - styleSpacing * (cols - 1)) / cols;
  const sortedNodes = [...safeNodes].sort((a, b) => {
    if (a.editorialOrder !== b.editorialOrder) return a.editorialOrder - b.editorialOrder;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });

  const columnHeights = new Array<number>(cols).fill(effectivePadding);
  const frames: Record<string, BoardRect> = {};

  let heroQuota = style === 'magazine' ? 3 : 0;
  let magazineHeroAssigned = false;

  sortedNodes.forEach((node, index) => {
    if ('groupFrame' in node.kind) {
      const maxY = Math.max(...columnHeights, effectivePadding);
      const rawH =
        Number.isFinite(node.frame?.height) && node.frame.height > 0 ? node.frame.height : 60;
      const headerHeight = Math.max(54, Math.min(86, rawH));
      frames[node.id] = { x: effectivePadding, y: maxY, width: usableWidth, height: headerHeight };
      const nextY = maxY + headerHeight + styleSpacing;
      columnHeights.fill(nextY);
      return;
    }

    if ('paletteStrip' in node.kind) {
      const maxY = Math.max(...columnHeights, effectivePadding);
      const stripHeight = style === 'compact' ? 56 : 76;
      frames[node.id] = { x: effectivePadding, y: maxY, width: usableWidth, height: stripHeight };
      const nextY = maxY + stripHeight + styleSpacing;
      columnHeights.fill(nextY);
      return;
    }

    if ('note' in node.kind) {
      const col = shortestColumnIndex(columnHeights);
      const x = effectivePadding + col * (colWidth + styleSpacing);
      const y = columnHeights[col];
      const textStr = typeof node.kind.note.text === 'string' ? node.kind.note.text : '';
      const fontSize = Number.isFinite(node.kind.note.fontSize) ? node.kind.note.fontSize : 14;
      const charCount = [...textStr].length;
      const estimatedLines = Math.max(3, Math.min(10, Math.trunc(charCount / 18) + 2));
      const height = Math.max(124, estimatedLines * Math.max(18, fontSize * 1.45) + 42);
      frames[node.id] = { x, y, width: colWidth, height };
      columnHeights[col] = y + height + styleSpacing;
      return;
    }

    if ('assetRef' in node.kind) {
      const { assetID, crop, weight } = node.kind.assetRef;
      const aspect = resolvedAspectRatio(assetID, crop, assetsById, style);
      const wantsHero =
        style === 'magazine' &&
        cols >= 3 &&
        heroQuota > 0 &&
        ((!magazineHeroAssigned && index === 0) ||
          weight >= 2 ||
          (index > 0 && index % 5 === 0));

      if (wantsHero) {
        const spanStart = bestTwoColumnSpanStart(columnHeights);
        if (spanStart !== null) {
          heroQuota -= 1;
          magazineHeroAssigned = true;
          const spanWidth = colWidth * 2 + styleSpacing;
          const clampedAspect = Math.max(0.85, Math.min(1.85, aspect));
          const height = spanWidth / clampedAspect;
          const y = Math.max(columnHeights[spanStart], columnHeights[spanStart + 1]);
          const x = effectivePadding + spanStart * (colWidth + styleSpacing);
          frames[node.id] = { x, y, width: spanWidth, height };
          const nextY = y + height + styleSpacing;
          columnHeights[spanStart] = nextY;
          columnHeights[spanStart + 1] = nextY;
          return;
        }
      }

      const col = shortestColumnIndex(columnHeights);
      const x = effectivePadding + col * (colWidth + styleSpacing);
      const y = columnHeights[col];
      const height = colWidth / aspect;
      frames[node.id] = { x, y, width: colWidth, height };
      columnHeights[col] = y + height + styleSpacing;
    }
  });

  const maxHeight = Math.max(...columnHeights, effectivePadding) + effectivePadding + 88;
  return {
    frames,
    orderedNodeIds: sortedNodes.map((n) => n.id),
    contentSize: { width: safeContainerWidth, height: Math.max(480, maxHeight) },
    columnWidth: colWidth,
    columnCount: cols,
  };
}

export function reflowNodesInsideGroupFrame(
  groupRect: BoardRect,
  childNodes: BoardNode[],
  assetsById: Map<string, AssetRecord>,
  headerHeight = 38,
  padding = 12,
  spacing = 10,
): Record<string, BoardRect> {
  if (!Array.isArray(childNodes) || childNodes.length === 0) return {};
  const innerX = groupRect.x + padding;
  const innerY = groupRect.y + headerHeight + padding * 0.6;
  const innerW = Math.max(80, groupRect.width - padding * 2);
  const innerH = Math.max(60, groupRect.height - headerHeight - padding * 1.6);

  const ordered = [...childNodes].sort((a, b) => {
    if (Math.abs(a.frame.y - b.frame.y) > 24) return a.frame.y - b.frame.y;
    if (Math.abs(a.frame.x - b.frame.x) > 12) return a.frame.x - b.frame.x;
    return a.editorialOrder - b.editorialOrder;
  });

  const ratios = ordered.map((node) => {
    if ('assetRef' in node.kind) {
      return resolvedAspectRatio(
        node.kind.assetRef.assetID,
        node.kind.assetRef.crop,
        assetsById,
        'balanced',
      );
    }
    const raw = node.frame.width / Math.max(1, node.frame.height);
    return Number.isFinite(raw) ? Math.max(0.65, Math.min(2.2, raw)) : 1.25;
  });

  const n = ordered.length;
  let bestFrames: Record<string, BoardRect> = {};
  let bestCoverage = -1;

  for (let rowCount = 1; rowCount <= Math.min(n, 6); rowCount++) {
    const totalGapsY = spacing * (rowCount - 1);
    const availH = Math.max(32, innerH - totalGapsY);
    const totalRatio = ratios.reduce((s, v) => s + v, 0);
    const targetRowRatio = totalRatio / rowCount;

    const rows: number[][] = [];
    let currentRow: number[] = [];
    let currentSum = 0;
    for (let idx = 0; idx < n; idx++) {
      currentRow.push(idx);
      currentSum += ratios[idx];
      const remainingRows = Math.max(0, rowCount - rows.length - 1);
      const remainingItems = n - idx - 1;
      if (
        remainingRows > 0 &&
        (remainingItems === remainingRows || currentSum >= targetRowRatio * 0.88)
      ) {
        rows.push(currentRow);
        currentRow = [];
        currentSum = 0;
      }
    }
    if (currentRow.length > 0) rows.push(currentRow);

    const naturalRowHeights = rows.map((r) => {
      const gapsX = spacing * Math.max(0, r.length - 1);
      const sumR = r.reduce((s, idx) => s + ratios[idx], 0);
      return Math.max(24, (innerW - gapsX) / Math.max(0.1, sumR));
    });

    const sumNaturalH = naturalRowHeights.reduce((s, h) => s + h, 0);
    const verticalScale = sumNaturalH > availH ? availH / sumNaturalH : 1.0;

    const candidate: Record<string, BoardRect> = {};
    let totalArea = 0;
    let cursorY = innerY;

    rows.forEach((r, rIdx) => {
      const rowH = Math.max(24, naturalRowHeights[rIdx] * verticalScale);
      const gapsX = spacing * Math.max(0, r.length - 1);
      const rawRowW = r.reduce((s, idx) => s + ratios[idx] * rowH, 0) + gapsX;
      const horizScale = rawRowW > innerW ? (innerW - gapsX) / Math.max(1, rawRowW - gapsX) : 1.0;
      const effectiveH = rowH * horizScale;

      let cursorX = innerX;
      for (const itemIdx of r) {
        const w = Math.max(24, ratios[itemIdx] * effectiveH);
        candidate[ordered[itemIdx].id] = { x: cursorX, y: cursorY, width: w, height: effectiveH };
        totalArea += w * effectiveH;
        cursorX += w + spacing;
      }
      cursorY += effectiveH + spacing;
    });

    if (totalArea > bestCoverage) {
      bestCoverage = totalArea;
      bestFrames = candidate;
    }
  }

  return bestFrames;
}

export function freezeIntoFreeform(
  document: MoodboardDocument,
  containerWidth: number,
  assetsById: Map<string, AssetRecord>,
): MoodboardDocument {
  const nodes = Array.isArray(document.nodes) ? document.nodes : [];
  const cfg: AutoLayoutConfig = isAutoEditorialMode(document.mode)
    ? document.mode.autoEditorial._0
    : { columns: 4, spacing: 16, style: 'balanced', showPaletteStrip: true };
  const solved = solveEditorialLayout(nodes, cfg, containerWidth, assetsById, 28);
  return {
    ...document,
    mode: { freeform: {} },
    nodes: nodes.map((n) => ({
      ...n,
      frame: solved.frames[n.id] ?? n.frame,
    })),
    viewportZoom: 1,
    viewportCenter: {
      x: solved.contentSize.width * 0.5,
      y: Math.min(solved.contentSize.height * 0.5, 420),
    },
  };
}

export function tidyNodesInFreeform(
  document: MoodboardDocument,
  selectedNodeIds: Set<string>,
  assetsById: Map<string, AssetRecord>,
): MoodboardDocument {
  const nodes = Array.isArray(document.nodes) ? document.nodes : [];
  const targets =
    selectedNodeIds.size >= 2 ? nodes.filter((n) => selectedNodeIds.has(n.id)) : nodes;
  if (targets.length === 0) return document;

  const minX = Math.min(...targets.map((n) => n.frame.x));
  const minY = Math.min(...targets.map((n) => n.frame.y));
  const maxX = Math.max(...targets.map((n) => n.frame.x + n.frame.width));
  const width = Math.max(760, Math.min(1440, maxX - minX + 56));

  const solved = solveEditorialLayout(
    targets,
    { columns: 4, spacing: 16, style: 'balanced', showPaletteStrip: true },
    width,
    assetsById,
    0,
  );
  return {
    ...document,
    nodes: nodes.map((n) => {
      const r = solved.frames[n.id];
      if (!r) return n;
      return {
        ...n,
        frame: { x: minX + r.x, y: minY + r.y, width: r.width, height: r.height },
      };
    }),
  };
}

function resolveAnchor(
  rect: BoardRect,
  anchor: ConnectorAnchor,
  norm: BoardPoint | null | undefined,
  other: BoardRect,
): BoardPoint {
  if (norm && Number.isFinite(norm.x) && Number.isFinite(norm.y)) {
    return {
      x: rect.x + Math.max(0, Math.min(1, norm.x)) * rect.width,
      y: rect.y + Math.max(0, Math.min(1, norm.y)) * rect.height,
    };
  }
  let resolved = anchor;
  if (resolved === 'auto') {
    const dx = other.x + other.width / 2 - (rect.x + rect.width / 2);
    const dy = other.y + other.height / 2 - (rect.y + rect.height / 2);
    if (Math.abs(dx) >= Math.abs(dy)) {
      resolved = dx >= 0 ? 'trailing' : 'leading';
    } else {
      resolved = dy >= 0 ? 'bottom' : 'top';
    }
  }
  switch (resolved) {
    case 'top':
      return { x: rect.x + rect.width / 2, y: rect.y };
    case 'bottom':
      return { x: rect.x + rect.width / 2, y: rect.y + rect.height };
    case 'leading':
      return { x: rect.x, y: rect.y + rect.height / 2 };
    case 'trailing':
      return { x: rect.x + rect.width, y: rect.y + rect.height / 2 };
    default:
      return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
  }
}

function connectorNormalOffset(
  rect: BoardRect,
  pt: BoardPoint,
  isPinpoint: boolean,
  otherPt: BoardPoint,
  dist: number,
): BoardPoint {
  if (isPinpoint) {
    const dx = otherPt.x - pt.x;
    const dy = otherPt.y - pt.y;
    const length = Math.max(1, Math.hypot(dx, dy));
    const pull = Math.min(dist * 0.65, length * 0.35);
    return { x: (dx / length) * pull, y: (dy / length) * pull };
  }
  if (Math.abs(pt.y - rect.y) < 1.5) return { x: 0, y: -dist };
  if (Math.abs(pt.y - (rect.y + rect.height)) < 1.5) return { x: 0, y: dist };
  if (Math.abs(pt.x - rect.x) < 1.5) return { x: -dist, y: 0 };
  if (Math.abs(pt.x - (rect.x + rect.width)) < 1.5) return { x: dist, y: 0 };
  return { x: (otherPt.x - pt.x) * 0.25, y: 0 };
}

export interface ConnectorSvgGeometry {
  path: string;
  start: BoardPoint;
  end: BoardPoint;
  c1: BoardPoint;
  c2: BoardPoint;
  mid: BoardPoint;
  arrowHeadPath: string;
}

export function buildConnectorSvgPath(
  conn: BoardConnector,
  fromRect: BoardRect,
  toRect: BoardRect,
): ConnectorSvgGeometry {
  const start = resolveAnchor(fromRect, conn.fromAnchor, conn.fromNormalizedPoint, toRect);
  const end = resolveAnchor(toRect, conn.toAnchor, conn.toNormalizedPoint, fromRect);
  const dist = Math.max(48, Math.hypot(end.x - start.x, end.y - start.y) * 0.36);

  const n1 = connectorNormalOffset(
    fromRect,
    start,
    Boolean(conn.fromNormalizedPoint),
    end,
    dist,
  );
  const n2 = connectorNormalOffset(
    toRect,
    end,
    Boolean(conn.toNormalizedPoint),
    start,
    dist,
  );
  const c1: BoardPoint = { x: start.x + n1.x, y: start.y + n1.y };
  const c2: BoardPoint = { x: end.x + n2.x, y: end.y + n2.y };

  let path: string;
  let mid: BoardPoint;
  let tangentSrc: BoardPoint;

  if (conn.style === 'straight') {
    path = `M ${start.x} ${start.y} L ${end.x} ${end.y}`;
    mid = { x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5 };
    tangentSrc = start;
  } else if (conn.style === 'elbow') {
    const mx = (start.x + end.x) * 0.5;
    path = `M ${start.x} ${start.y} L ${mx} ${start.y} L ${mx} ${end.y} L ${end.x} ${end.y}`;
    mid = { x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5 };
    // Vertical elbow (start.x === end.x) has mx === end.x; use the vertical segment to avoid 0-radian arrow
    tangentSrc = Math.abs(end.x - mx) >= 0.5 ? { x: mx, y: end.y } : { x: mx, y: start.y };
  } else {
    path = `M ${start.x} ${start.y} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${end.x} ${end.y}`;
    mid = {
      x: 0.125 * start.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * end.x,
      y: 0.125 * start.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * end.y,
    };
    if (Math.hypot(end.x - c2.x, end.y - c2.y) >= 0.5) {
      tangentSrc = c2;
    } else if (Math.hypot(end.x - c1.x, end.y - c1.y) >= 0.5) {
      tangentSrc = c1;
    } else {
      tangentSrc = start;
    }
  }

  let arrowHeadPath = '';
  const segLen = Math.hypot(end.x - tangentSrc.x, end.y - tangentSrc.y);
  if (segLen >= 0.5 && Number.isFinite(segLen)) {
    const angle = Math.atan2(end.y - tangentSrc.y, end.x - tangentSrc.x);
    const arrowLen = 10;
    const spread = Math.PI / 6.5;
    const ax1 = end.x - arrowLen * Math.cos(angle - spread);
    const ay1 = end.y - arrowLen * Math.sin(angle - spread);
    const ax2 = end.x - arrowLen * Math.cos(angle + spread);
    const ay2 = end.y - arrowLen * Math.sin(angle + spread);
    arrowHeadPath = `M ${ax1} ${ay1} L ${end.x} ${end.y} L ${ax2} ${ay2}`;
  }

  return { path, start, end, c1, c2, mid, arrowHeadPath };
}

/** Smooth quadratic Bezier SVG path matching macOS `MoodboardCanvasView` ink rendering. */
export function buildInkStrokeSvgPath(points: InkStrokePoint[]): string {
  if (!Array.isArray(points) || points.length < 2) return '';
  const safePoints = points.filter(
    (pt) => pt && Number.isFinite(pt.x) && Number.isFinite(pt.y),
  );
  if (safePoints.length < 2) return '';
  if (safePoints.length === 2) {
    return `M ${safePoints[0].x} ${safePoints[0].y} L ${safePoints[1].x} ${safePoints[1].y}`;
  }
  const cmds: string[] = [`M ${safePoints[0].x} ${safePoints[0].y}`];
  for (let i = 1; i < safePoints.length - 1; i++) {
    const midX = (safePoints[i].x + safePoints[i + 1].x) * 0.5;
    const midY = (safePoints[i].y + safePoints[i + 1].y) * 0.5;
    cmds.push(`Q ${safePoints[i].x} ${safePoints[i].y} ${midX} ${midY}`);
  }
  const last = safePoints[safePoints.length - 1];
  cmds.push(`L ${last.x} ${last.y}`);
  return cmds.join(' ');
}

const WINDOWS_RESERVED_BASENAMES = new Set([
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
]);

/** Sanitize a moodboard title into a safe Windows filename stem (without extension). */
export function sanitizeExportFileName(
  rawTitle: string | null | undefined,
  fallback = '未命名情绪板',
): string {
  const cleaned = (rawTitle ?? '')
    // eslint-disable-next-line no-control-regex
    .replace(/[<>:"/\\|?*\u0000-\u001F]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/[. ]+$/g, '')
    .slice(0, 120);
  if (!cleaned) return fallback;
  if (WINDOWS_RESERVED_BASENAMES.has(cleaned.toUpperCase())) {
    return `${cleaned}_board`;
  }
  return cleaned;
}
