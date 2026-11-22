import { getAssetAspectRatio } from '../models/core.js';
import type { AssetRecord, UUID } from '../models/core.js';
import {
  createDefaultAutoLayoutConfig,
  rectMaxX,
  rectMinX,
  rectMinY,
} from '../models/moodboard.js';
import type {
  AutoLayoutConfig,
  BoardNode,
  BoardRect,
  EditorialStyle,
  MoodboardDocument,
  NormalizedCropRect,
} from '../models/moodboard.js';

export interface BoardSize {
  width: number;
  height: number;
}

export interface EditorialLayoutResult {
  frames: Record<UUID, BoardRect>;
  orderedNodeIDs: UUID[];
  contentSize: BoardSize;
  columnWidth: number;
  columnCount: number;
}

export type AssetLookup = Record<UUID, AssetRecord> | ReadonlyMap<UUID, AssetRecord>;

function lookupAsset(assetsByID: AssetLookup, id: UUID): AssetRecord | undefined {
  if (assetsByID instanceof Map) {
    return assetsByID.get(id);
  }
  return (assetsByID as Record<UUID, AssetRecord>)[id];
}

function compareAscii(a: string, b: string): number {
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}

function resolvedAspectRatio(
  assetID: UUID,
  crop: NormalizedCropRect | null | undefined,
  assetsByID: AssetLookup,
  style: EditorialStyle,
): number {
  const asset = lookupAsset(assetsByID, assetID);
  let ratio = asset ? getAssetAspectRatio(asset) : 1.25;
  if (crop && crop.width > 0.05 && crop.height > 0.05) {
    ratio = ratio * (crop.width / crop.height);
  }
  switch (style) {
    case 'compact':
      return Math.max(0.8, Math.min(1.32, ratio));
    case 'magazine':
      return Math.max(0.56, Math.min(2.15, ratio));
    case 'balanced':
      return Math.max(0.64, Math.min(1.85, ratio));
  }
}

function shortestColumnIndex(heights: readonly number[]): number {
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

function bestTwoColumnSpanStart(heights: readonly number[]): number | null {
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

/**
 * Deterministic O(N) auto-editorial Bento / Masonry layout solver supporting
 * `balanced`, `magazine` (Hero 2-column span), and `compact` editorial styles,
 * plus zero-jump freezing from `autoEditorial` into `freeform` and smart group frame reflow.
 *
 * Exact 1:1 port of Swift `EditorialLayoutSolver` (EditorialLayoutSolver.swift).
 */
export function solveEditorialLayout(
  nodes: readonly BoardNode[],
  config: AutoLayoutConfig,
  containerWidth: number,
  assetsByID: AssetLookup,
  padding = 28,
): EditorialLayoutResult {
  let effectivePadding: number;
  switch (config.style) {
    case 'magazine':
      effectivePadding = Math.max(36, padding + 10);
      break;
    case 'balanced':
      effectivePadding = Math.max(22, padding);
      break;
    case 'compact':
      effectivePadding = Math.max(12, Math.min(padding, 14));
      break;
  }

  const usableWidth = Math.max(320, containerWidth - effectivePadding * 2);

  let styleSpacing: number;
  switch (config.style) {
    case 'magazine':
      styleSpacing = Math.max(26, config.spacing + 10);
      break;
    case 'balanced':
      styleSpacing = Math.max(15, config.spacing);
      break;
    case 'compact':
      styleSpacing = 6;
      break;
  }

  let cols: number;
  switch (config.style) {
    case 'magazine':
      cols = Math.max(2, Math.min(3, Math.trunc((usableWidth + styleSpacing) / 280.0)));
      break;
    case 'balanced':
      cols = Math.max(3, Math.min(4, Math.trunc((usableWidth + styleSpacing) / 220.0)));
      break;
    case 'compact':
      cols = Math.max(5, Math.min(7, Math.trunc((usableWidth + styleSpacing) / 142.0)));
      break;
  }

  const colWidth = (usableWidth - styleSpacing * (cols - 1)) / cols;
  const sortedNodes = [...nodes].sort((lhs, rhs) => {
    if (lhs.editorialOrder !== rhs.editorialOrder) {
      return lhs.editorialOrder - rhs.editorialOrder;
    }
    return compareAscii(lhs.id, rhs.id);
  });

  const columnHeights = new Array<number>(cols).fill(effectivePadding);
  const frames: Record<UUID, BoardRect> = {};

  let heroQuota = config.style === 'magazine' ? 3 : 0;
  let magazineHeroAssigned = false;

  for (let index = 0; index < sortedNodes.length; index++) {
    const node = sortedNodes[index];
    switch (node.kind.type) {
      case 'groupFrame': {
        const maxY = Math.max(...columnHeights);
        const headerHeight = Math.max(54.0, Math.min(86.0, node.frame.height > 0 ? node.frame.height : 60.0));
        frames[node.id] = {
          x: effectivePadding,
          y: maxY,
          width: usableWidth,
          height: headerHeight,
        };
        const nextY = maxY + headerHeight + styleSpacing;
        for (let c = 0; c < cols; c++) columnHeights[c] = nextY;
        break;
      }

      case 'paletteStrip': {
        const maxY = Math.max(...columnHeights);
        const stripHeight = config.style === 'compact' ? 56.0 : 76.0;
        frames[node.id] = {
          x: effectivePadding,
          y: maxY,
          width: usableWidth,
          height: stripHeight,
        };
        const nextY = maxY + stripHeight + styleSpacing;
        for (let c = 0; c < cols; c++) columnHeights[c] = nextY;
        break;
      }

      case 'note': {
        const col = shortestColumnIndex(columnHeights);
        const x = effectivePadding + col * (colWidth + styleSpacing);
        const y = columnHeights[col];
        const estimatedLines = Math.max(3, Math.min(10, Math.trunc(node.kind.text.length / 18.0) + 2));
        const height = Math.max(124.0, estimatedLines * Math.max(18.0, node.kind.fontSize * 1.45) + 42.0);
        frames[node.id] = { x, y, width: colWidth, height };
        columnHeights[col] = y + height + styleSpacing;
        break;
      }

      case 'assetRef': {
        const aspect = resolvedAspectRatio(node.kind.assetID, node.kind.crop, assetsByID, config.style);
        let wantsHero = false;
        if (config.style === 'magazine' && cols >= 3 && heroQuota > 0) {
          if (!magazineHeroAssigned && index === 0) {
            wantsHero = true;
          } else if (node.kind.weight >= 2) {
            wantsHero = true;
          } else if (index > 0 && index % 5 === 0) {
            wantsHero = true;
          }
        }

        const spanStart = wantsHero ? bestTwoColumnSpanStart(columnHeights) : null;
        if (wantsHero && spanStart !== null) {
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
        } else {
          const col = shortestColumnIndex(columnHeights);
          const x = effectivePadding + col * (colWidth + styleSpacing);
          const y = columnHeights[col];
          const height = colWidth / aspect;
          frames[node.id] = { x, y, width: colWidth, height };
          columnHeights[col] = y + height + styleSpacing;
        }
        break;
      }
    }
  }

  const maxHeight = (columnHeights.length > 0 ? Math.max(...columnHeights) : effectivePadding) + effectivePadding + 88.0;

  return {
    frames,
    orderedNodeIDs: sortedNodes.map((n) => n.id),
    contentSize: { width: containerWidth, height: Math.max(480, maxHeight) },
    columnWidth: colWidth,
    columnCount: cols,
  };
}

/**
 * Smart Auto-Layout Frame reflow: packs all enclosed nodes cleanly inside `groupRect`
 * using justified rows and proportionally scales them so every child stays strictly within
 * the resized frame bounds in real time.
 *
 * Exact 1:1 port of Swift `EditorialLayoutSolver.reflowNodesInsideGroupFrame`.
 */
export function reflowNodesInsideGroupFrame(
  groupRect: BoardRect,
  childNodes: readonly BoardNode[],
  assetsByID: AssetLookup,
  headerHeight = 38,
  padding = 12,
  spacing = 10,
): Record<UUID, BoardRect> {
  if (childNodes.length === 0) return {};

  const innerX = groupRect.x + padding;
  const innerY = groupRect.y + headerHeight + padding * 0.6;
  const innerW = Math.max(80, groupRect.width - padding * 2);
  const innerH = Math.max(60, groupRect.height - headerHeight - padding * 1.6);

  const ordered = [...childNodes].sort((lhs, rhs) => {
    if (Math.abs(rectMinY(lhs.frame) - rectMinY(rhs.frame)) > 24) {
      return rectMinY(lhs.frame) - rectMinY(rhs.frame);
    }
    if (Math.abs(rectMinX(lhs.frame) - rectMinX(rhs.frame)) > 12) {
      return rectMinX(lhs.frame) - rectMinX(rhs.frame);
    }
    return lhs.editorialOrder - rhs.editorialOrder;
  });

  const ratios: number[] = ordered.map((node) => {
    if (node.kind.type === 'assetRef') {
      return resolvedAspectRatio(node.kind.assetID, node.kind.crop, assetsByID, 'balanced');
    }
    return Math.max(0.65, Math.min(2.2, node.frame.width / Math.max(1, node.frame.height)));
  });

  const n = ordered.length;
  let bestFrames: Record<UUID, BoardRect> = {};
  let bestCoverage = -1;

  const maxRows = Math.min(n, 6);
  const totalRatio = ratios.reduce((acc, r) => acc + r, 0);

  for (let rowCount = 1; rowCount <= maxRows; rowCount++) {
    const totalGapsY = spacing * (rowCount - 1);
    const availH = Math.max(32, innerH - totalGapsY);
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

    const naturalRowHeights: number[] = [];
    for (const r of rows) {
      const gapsX = spacing * Math.max(0, r.length - 1);
      const sumR = r.reduce((acc, idx) => acc + ratios[idx], 0);
      const rowH = Math.max(24, (innerW - gapsX) / Math.max(0.1, sumR));
      naturalRowHeights.push(rowH);
    }

    const sumNaturalH = naturalRowHeights.reduce((acc, h) => acc + h, 0);
    const verticalScale = sumNaturalH > availH ? availH / sumNaturalH : 1.0;

    const candidate: Record<UUID, BoardRect> = {};
    let totalPaintedArea = 0;
    let cursorY = innerY;

    for (let rIdx = 0; rIdx < rows.length; rIdx++) {
      const r = rows[rIdx];
      const rowH = Math.max(24, naturalRowHeights[rIdx] * verticalScale);
      const gapsX = spacing * Math.max(0, r.length - 1);
      const rawRowW = r.reduce((acc, idx) => acc + ratios[idx] * rowH, 0) + gapsX;
      const horizScale =
        rawRowW > innerW ? (innerW - gapsX) / Math.max(1, rawRowW - gapsX) : 1.0;
      const effectiveH = rowH * horizScale;

      let cursorX = innerX;
      for (const itemIdx of r) {
        const w = Math.max(24, ratios[itemIdx] * effectiveH);
        candidate[ordered[itemIdx].id] = { x: cursorX, y: cursorY, width: w, height: effectiveH };
        totalPaintedArea += w * effectiveH;
        cursorX += w + spacing;
      }
      cursorY += effectiveH + spacing;
    }

    if (totalPaintedArea > bestCoverage) {
      bestCoverage = totalPaintedArea;
      bestFrames = candidate;
    }
  }

  return bestFrames;
}

/**
 * Freezes the exact computed Auto Editorial visual frames directly into every node's `frame`
 * and switches the document to `freeform` so nothing visually jumps.
 */
export function freezeIntoFreeform(
  document: MoodboardDocument,
  containerWidth: number,
  assetsByID: AssetLookup,
): MoodboardDocument {
  const config =
    document.mode.type === 'autoEditorial'
      ? document.mode.config
      : createDefaultAutoLayoutConfig();

  const solved = solveEditorialLayout(document.nodes, config, containerWidth, assetsByID);
  const nodes = document.nodes.map((node) => {
    const rect = solved.frames[node.id];
    return rect ? { ...node, frame: rect } : node;
  });

  return {
    ...document,
    nodes,
    mode: { type: 'freeform' },
    viewportZoom: 1.0,
    viewportCenter: {
      x: solved.contentSize.width * 0.5,
      y: Math.min(solved.contentSize.height * 0.5, 420),
    },
  };
}

/**
 * Re-tidies either the selected nodes (around their bounding box origin) or the entire board
 * into crisp editorial alignment while remaining in Freeform mode.
 */
export function tidyNodesInFreeform(
  document: MoodboardDocument,
  selectedNodeIDs: ReadonlySet<UUID>,
  assetsByID: AssetLookup,
): MoodboardDocument {
  const targetNodes =
    selectedNodeIDs.size >= 2
      ? document.nodes.filter((n) => selectedNodeIDs.has(n.id))
      : document.nodes;
  if (targetNodes.length === 0) return { ...document };

  const minX = Math.min(...targetNodes.map((n) => rectMinX(n.frame)));
  const minY = Math.min(...targetNodes.map((n) => rectMinY(n.frame)));
  const maxX = Math.max(...targetNodes.map((n) => rectMaxX(n.frame)));
  const width = Math.max(760, Math.min(1440, maxX - minX + 56));

  const solved = solveEditorialLayout(
    targetNodes,
    createDefaultAutoLayoutConfig({ columns: 4, spacing: 16, style: 'balanced' }),
    width,
    assetsByID,
    0,
  );

  const nodes = document.nodes.map((node) => {
    const rect = solved.frames[node.id];
    if (!rect) return node;
    return {
      ...node,
      frame: {
        x: minX + rect.x,
        y: minY + rect.y,
        width: rect.width,
        height: rect.height,
      },
    };
  });

  return { ...document, nodes };
}

export const EditorialLayoutSolver = {
  solve: solveEditorialLayout,
  reflowNodesInsideGroupFrame,
  freezeIntoFreeform,
  tidyNodesInFreeform,
} as const;
