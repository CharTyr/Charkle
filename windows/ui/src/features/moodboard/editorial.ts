//! Deterministic TypeScript mirror of `crates/charkle-core/src/layout/editorial.rs`
//! and macOS `EditorialLayoutSolver.swift` enabling 60/120 FPS Auto Editorial drag-reorder
//! and Smart Auto-Layout GroupFrame reflow with zero IPC round-trips.

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
  type MoodboardDocument,
  type NormalizedCropRect,
  type NoteStyle,
} from '../../types/domain';

export const NOTE_STYLE_PALETTE: Record<
  NoteStyle,
  { label: string; bg: string; fg: string; border: string }
> = {
  paper: { label: '素纸', bg: '#FFFFFF', fg: '#1D1F23', border: '#D9DBDE' },
  ink: { label: '墨黑', bg: '#1D1F24', fg: '#F1F2F4', border: '#3A3D45' },
  warm: { label: '暖羊皮', bg: '#F7F0E4', fg: '#392F22', border: '#C9B79C' },
  sage: { label: '鼠尾草', bg: '#E8F0EA', fg: '#203227', border: '#9AB5A3' },
  slate: { label: '石板蓝', bg: '#E9EEF3', fg: '#1F2B36', border: '#9EB0C2' },
};

export const GROUP_TINT_PALETTE: Record<
  GroupTint,
  { label: string; accent: string; bgLight: string; bgDark: string }
> = {
  neutral: { label: '中性灰', accent: '#7D838B', bgLight: 'rgba(125,131,139,0.08)', bgDark: 'rgba(125,131,139,0.14)' },
  sand: { label: '暖沙', accent: '#B5956B', bgLight: 'rgba(181,149,107,0.10)', bgDark: 'rgba(181,149,107,0.15)' },
  sage: { label: '鼠尾草', accent: '#6B8E76', bgLight: 'rgba(107,142,118,0.10)', bgDark: 'rgba(107,142,118,0.15)' },
  slate: { label: '石板灰', accent: '#627A94', bgLight: 'rgba(98,122,148,0.10)', bgDark: 'rgba(98,122,148,0.15)' },
  terracotta: { label: '陶土', accent: '#BA6B55', bgLight: 'rgba(186,107,85,0.10)', bgDark: 'rgba(186,107,85,0.15)' },
  ocean: { label: '深海蓝', accent: '#4D7E97', bgLight: 'rgba(77,126,151,0.10)', bgDark: 'rgba(77,126,151,0.15)' },
};

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
  if (crop && crop.width > 0.05 && crop.height > 0.05) {
    ratio *= crop.width / crop.height;
  }
  if (style === 'compact') return Math.max(0.8, Math.min(1.32, ratio));
  if (style === 'magazine') return Math.max(0.56, Math.min(2.15, ratio));
  return Math.max(0.64, Math.min(1.85, ratio));
}

function shortestColumnIndex(heights: number[]): number {
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
  const effectivePadding =
    config.style === 'magazine'
      ? Math.max(36, padding + 10)
      : config.style === 'balanced'
        ? Math.max(22, padding)
        : Math.max(12, Math.min(padding, 14));

  const usableWidth = Math.max(320, containerWidth - effectivePadding * 2);
  const styleSpacing =
    config.style === 'magazine'
      ? Math.max(26, config.spacing + 10)
      : config.style === 'balanced'
        ? Math.max(15, config.spacing)
        : 6;

  const cols =
    config.style === 'magazine'
      ? Math.max(2, Math.min(3, Math.trunc((usableWidth + styleSpacing) / 280)))
      : config.style === 'balanced'
        ? Math.max(3, Math.min(4, Math.trunc((usableWidth + styleSpacing) / 220)))
        : Math.max(5, Math.min(7, Math.trunc((usableWidth + styleSpacing) / 142)));

  const colWidth = (usableWidth - styleSpacing * (cols - 1)) / cols;
  const sortedNodes = [...nodes].sort((a, b) => {
    if (a.editorialOrder !== b.editorialOrder) return a.editorialOrder - b.editorialOrder;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });

  const columnHeights = new Array<number>(cols).fill(effectivePadding);
  const frames: Record<string, BoardRect> = {};

  let heroQuota = config.style === 'magazine' ? 3 : 0;
  let magazineHeroAssigned = false;

  sortedNodes.forEach((node, index) => {
    if ('groupFrame' in node.kind) {
      const maxY = Math.max(...columnHeights, effectivePadding);
      const rawH = node.frame.height > 0 ? node.frame.height : 60;
      const headerHeight = Math.max(54, Math.min(86, rawH));
      frames[node.id] = { x: effectivePadding, y: maxY, width: usableWidth, height: headerHeight };
      const nextY = maxY + headerHeight + styleSpacing;
      columnHeights.fill(nextY);
      return;
    }

    if ('paletteStrip' in node.kind) {
      const maxY = Math.max(...columnHeights, effectivePadding);
      const stripHeight = config.style === 'compact' ? 56 : 76;
      frames[node.id] = { x: effectivePadding, y: maxY, width: usableWidth, height: stripHeight };
      const nextY = maxY + stripHeight + styleSpacing;
      columnHeights.fill(nextY);
      return;
    }

    if ('note' in node.kind) {
      const col = shortestColumnIndex(columnHeights);
      const x = effectivePadding + col * (colWidth + styleSpacing);
      const y = columnHeights[col];
      const charCount = [...node.kind.note.text].length;
      const estimatedLines = Math.max(3, Math.min(10, Math.trunc(charCount / 18) + 2));
      const height = Math.max(
        124,
        estimatedLines * Math.max(18, node.kind.note.fontSize * 1.45) + 42,
      );
      frames[node.id] = { x, y, width: colWidth, height };
      columnHeights[col] = y + height + styleSpacing;
      return;
    }

    if ('assetRef' in node.kind) {
      const { assetID, crop, weight } = node.kind.assetRef;
      const aspect = resolvedAspectRatio(assetID, crop, assetsById, config.style);
      const wantsHero =
        config.style === 'magazine' &&
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
    contentSize: { width: containerWidth, height: Math.max(480, maxHeight) },
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
  if (childNodes.length === 0) return {};
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
    return Math.max(0.65, Math.min(2.2, node.frame.width / Math.max(1, node.frame.height)));
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
      const remainingRows = rowCount - rows.length - 1;
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
  const cfg: AutoLayoutConfig = isAutoEditorialMode(document.mode)
    ? document.mode.autoEditorial._0
    : { columns: 4, spacing: 16, style: 'balanced', showPaletteStrip: true };
  const solved = solveEditorialLayout(document.nodes, cfg, containerWidth, assetsById, 28);
  return {
    ...document,
    mode: { freeform: {} },
    nodes: document.nodes.map((n) => ({
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
  const targets =
    selectedNodeIds.size >= 2
      ? document.nodes.filter((n) => selectedNodeIds.has(n.id))
      : document.nodes;
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
    nodes: document.nodes.map((n) => {
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
  if (norm) {
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

export function buildConnectorSvgPath(
  conn: BoardConnector,
  fromRect: BoardRect,
  toRect: BoardRect,
): { path: string; start: BoardPoint; end: BoardPoint; mid: BoardPoint } {
  const start = resolveAnchor(fromRect, conn.fromAnchor, conn.fromNormalizedPoint, toRect);
  const end = resolveAnchor(toRect, conn.toAnchor, conn.toNormalizedPoint, fromRect);
  const mid = { x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 };

  if (conn.style === 'straight') {
    return { path: `M ${start.x} ${start.y} L ${end.x} ${end.y}`, start, end, mid };
  }
  if (conn.style === 'elbow') {
    const mx = (start.x + end.x) / 2;
    return {
      path: `M ${start.x} ${start.y} L ${mx} ${start.y} L ${mx} ${end.y} L ${end.x} ${end.y}`,
      start,
      end,
      mid,
    };
  }
  const dx = Math.max(48, Math.abs(end.x - start.x) * 0.45);
  const c1x = start.x + (end.x >= start.x ? dx : -dx);
  const c2x = end.x - (end.x >= start.x ? dx : -dx);
  return {
    path: `M ${start.x} ${start.y} C ${c1x} ${start.y}, ${c2x} ${end.y}, ${end.x} ${end.y}`,
    start,
    end,
    mid,
  };
}
