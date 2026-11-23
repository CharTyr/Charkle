import {
  createDefaultAutoLayoutConfig,
  rectMaxX,
  rectMinX,
  rectMinY,
  solveEditorialLayout,
  tidyNodesInFreeform,
} from '@charkle/shared';
import type {
  AssetRecord,
  BoardConnector,
  BoardNode,
  BoardPoint,
  BoardRect,
  ConnectorAnchor,
  ConnectorStyle,
  EditorialStyle,
  InkStrokePoint,
  MoodboardDocument,
  UUID,
} from '@charkle/shared';

export type MoodboardTool = 'select' | 'pan' | 'connector' | 'pen' | 'eraser';

export type ResizeHandle =
  | 'nw'
  | 'n'
  | 'ne'
  | 'e'
  | 'se'
  | 's'
  | 'sw'
  | 'w';

export interface CameraState {
  centerX: number;
  centerY: number;
  zoom: number;
}

export const MIN_FREEFORM_ZOOM = 0.15;
export const MAX_FREEFORM_ZOOM = 4.0;

export function clampZoom(zoom: number): number {
  return Math.max(MIN_FREEFORM_ZOOM, Math.min(MAX_FREEFORM_ZOOM, zoom));
}

export function worldToScreen(
  point: BoardPoint,
  camera: CameraState,
  viewportWidth: number,
  viewportHeight: number,
): BoardPoint {
  return {
    x: (point.x - camera.centerX) * camera.zoom + viewportWidth * 0.5,
    y: (point.y - camera.centerY) * camera.zoom + viewportHeight * 0.5,
  };
}

export function screenToWorld(
  point: BoardPoint,
  camera: CameraState,
  viewportWidth: number,
  viewportHeight: number,
): BoardPoint {
  return {
    x: (point.x - viewportWidth * 0.5) / camera.zoom + camera.centerX,
    y: (point.y - viewportHeight * 0.5) / camera.zoom + camera.centerY,
  };
}

export function zoomCameraAtScreenPoint(
  camera: CameraState,
  nextZoomRaw: number,
  anchorScreen: BoardPoint,
  viewportWidth: number,
  viewportHeight: number,
): CameraState {
  const nextZoom = clampZoom(nextZoomRaw);
  const worldBefore = screenToWorld(anchorScreen, camera, viewportWidth, viewportHeight);
  return {
    zoom: nextZoom,
    centerX: worldBefore.x - (anchorScreen.x - viewportWidth * 0.5) / nextZoom,
    centerY: worldBefore.y - (anchorScreen.y - viewportHeight * 0.5) / nextZoom,
  };
}

export function computeFitCamera(
  nodes: readonly BoardNode[],
  viewportWidth: number,
  viewportHeight: number,
  margin = 72,
  topClearance = 64,
  bottomClearance = 96,
): CameraState {
  if (nodes.length === 0) {
    return {
      centerX: viewportWidth * 0.5,
      centerY: viewportHeight * 0.5 - (topClearance - bottomClearance) * 0.5,
      zoom: 1.0,
    };
  }
  let minX = Number.POSITIVE_INFINITY;
  let minY = Number.POSITIVE_INFINITY;
  let maxX = Number.NEGATIVE_INFINITY;
  let maxY = Number.NEGATIVE_INFINITY;
  for (const node of nodes) {
    minX = Math.min(minX, node.frame.x);
    minY = Math.min(minY, node.frame.y);
    maxX = Math.max(maxX, node.frame.x + node.frame.width);
    maxY = Math.max(maxY, node.frame.y + node.frame.height);
  }
  const contentW = Math.max(120, maxX - minX);
  const contentH = Math.max(120, maxY - minY);
  const availW = Math.max(240, viewportWidth - margin * 2);
  const availH = Math.max(200, viewportHeight - topClearance - bottomClearance - 24);
  const zoom = Math.max(0.22, Math.min(1.6, Math.min(availW / contentW, availH / contentH)));
  const verticalBiasPx = (topClearance - bottomClearance) * 0.5;
  return {
    centerX: (minX + maxX) * 0.5,
    centerY: (minY + maxY) * 0.5 - verticalBiasPx / zoom,
    zoom,
  };
}

export function getNodeMinSize(kind: BoardNode['kind']['type']): { width: number; height: number } {
  switch (kind) {
    case 'note':
      return { width: 140, height: 96 };
    case 'groupFrame':
      return { width: 180, height: 120 };
    case 'paletteStrip':
      return { width: 160, height: 48 };
    case 'assetRef':
      return { width: 84, height: 60 };
  }
}

export function rectsIntersect(a: BoardRect, b: BoardRect): boolean {
  return (
    a.x <= b.x + b.width &&
    a.x + a.width >= b.x &&
    a.y <= b.y + b.height &&
    a.y + a.height >= b.y
  );
}

export function findNodesInsideGroupFrame(
  groupNode: BoardNode,
  allNodes: readonly BoardNode[],
): BoardNode[] {
  const g = groupNode.frame;
  return allNodes.filter((n) => {
    if (n.id === groupNode.id || n.kind.type === 'groupFrame') return false;
    const cx = n.frame.x + n.frame.width * 0.5;
    const cy = n.frame.y + n.frame.height * 0.5;
    return cx >= g.x && cx <= g.x + g.width && cy >= g.y && cy <= g.y + g.height;
  });
}

export interface SnapResult {
  dx: number;
  dy: number;
  guidesX: number[];
  guidesY: number[];
}

/**
 * Smart alignment snap guides against sibling nodes (6px screen-space threshold).
 */
export function computeSnapDelta(
  movingRect: BoardRect,
  siblings: readonly BoardRect[],
  zoom: number,
  screenThreshold = 6,
): SnapResult {
  const threshold = screenThreshold / Math.max(0.15, zoom);
  const movingX = [
    movingRect.x,
    movingRect.x + movingRect.width * 0.5,
    movingRect.x + movingRect.width,
  ];
  const movingY = [
    movingRect.y,
    movingRect.y + movingRect.height * 0.5,
    movingRect.y + movingRect.height,
  ];

  let bestDx: number | null = null;
  let bestDistX = threshold + 0.001;
  let snapGuideX: number | null = null;

  let bestDy: number | null = null;
  let bestDistY = threshold + 0.001;
  let snapGuideY: number | null = null;

  for (const sib of siblings) {
    const sibX = [sib.x, sib.x + sib.width * 0.5, sib.x + sib.width];
    const sibY = [sib.y, sib.y + sib.height * 0.5, sib.y + sib.height];

    for (const mx of movingX) {
      for (const sx of sibX) {
        const d = Math.abs(sx - mx);
        if (d < bestDistX) {
          bestDistX = d;
          bestDx = sx - mx;
          snapGuideX = sx;
        }
      }
    }

    for (const my of movingY) {
      for (const sy of sibY) {
        const d = Math.abs(sy - my);
        if (d < bestDistY) {
          bestDistY = d;
          bestDy = sy - my;
          snapGuideY = sy;
        }
      }
    }
  }

  return {
    dx: bestDx ?? 0,
    dy: bestDy ?? 0,
    guidesX: snapGuideX !== null ? [snapGuideX] : [],
    guidesY: snapGuideY !== null ? [snapGuideY] : [],
  };
}

/**
 * Resize a node frame across 8 handles (4 corners + 4 edges) respecting rotation & aspect lock.
 */
export function computeResizedFrame(
  startFrame: BoardRect,
  handle: ResizeHandle,
  deltaWorldX: number,
  deltaWorldY: number,
  rotationDegrees: number,
  minSize: { width: number; height: number },
  lockAspect: boolean,
): BoardRect {
  const rad = (-rotationDegrees * Math.PI) / 180;
  const cos = Math.cos(rad);
  const sin = Math.sin(rad);
  const localDx = deltaWorldX * cos - deltaWorldY * sin;
  const localDy = deltaWorldX * sin + deltaWorldY * cos;

  const isWest = handle === 'w' || handle === 'nw' || handle === 'sw';
  const isEast = handle === 'e' || handle === 'ne' || handle === 'se';
  const isNorth = handle === 'n' || handle === 'nw' || handle === 'ne';
  const isSouth = handle === 's' || handle === 'sw' || handle === 'se';
  const isCorner = (isWest || isEast) && (isNorth || isSouth);

  let nextW = startFrame.width;
  let nextH = startFrame.height;

  if (isEast) nextW = startFrame.width + localDx;
  if (isWest) nextW = startFrame.width - localDx;
  if (isSouth) nextH = startFrame.height + localDy;
  if (isNorth) nextH = startFrame.height - localDy;

  nextW = Math.max(minSize.width, nextW);
  nextH = Math.max(minSize.height, nextH);

  if (lockAspect && isCorner && startFrame.height > 0 && startFrame.width > 0) {
    const aspect = startFrame.width / startFrame.height;
    const scaleW = nextW / startFrame.width;
    const scaleH = nextH / startFrame.height;
    if (Math.abs(scaleW - 1) >= Math.abs(scaleH - 1)) {
      nextH = Math.max(minSize.height, nextW / aspect);
      nextW = nextH * aspect;
    } else {
      nextW = Math.max(minSize.width, nextH * aspect);
      nextH = nextW / aspect;
    }
  }

  const dw = nextW - startFrame.width;
  const dh = nextH - startFrame.height;

  // Shift center in local space so the opposite edge/corner remains pinned
  const localCenterShiftX = isEast ? dw * 0.5 : isWest ? -dw * 0.5 : 0;
  const localCenterShiftY = isSouth ? dh * 0.5 : isNorth ? -dh * 0.5 : 0;

  const invRad = (rotationDegrees * Math.PI) / 180;
  const invCos = Math.cos(invRad);
  const invSin = Math.sin(invRad);
  const worldCenterShiftX = localCenterShiftX * invCos - localCenterShiftY * invSin;
  const worldCenterShiftY = localCenterShiftX * invSin + localCenterShiftY * invCos;

  const nextCenterX = startFrame.x + startFrame.width * 0.5 + worldCenterShiftX;
  const nextCenterY = startFrame.y + startFrame.height * 0.5 + worldCenterShiftY;

  return {
    x: nextCenterX - nextW * 0.5,
    y: nextCenterY - nextH * 0.5,
    width: nextW,
    height: nextH,
  };
}

/**
 * Snap rotation degrees: Shift -> 15° increments, otherwise magnetic ±3° at cardinal angles.
 */
export function snapRotationDegrees(rawDegrees: number, shiftPressed: boolean): number {
  let normalized = ((rawDegrees % 360) + 540) % 360 - 180;
  if (shiftPressed) {
    normalized = Math.round(normalized / 15) * 15;
  } else {
    for (const cardinal of [-180, -90, 0, 90, 180]) {
      if (Math.abs(normalized - cardinal) <= 3) {
        normalized = cardinal;
        break;
      }
    }
  }
  return normalized === -180 ? 180 : normalized;
}

/**
 * Rotate a local offset around a node center.
 */
function rotateAroundCenter(point: BoardPoint, center: BoardPoint, rotationDegrees: number): BoardPoint {
  if (Math.abs(rotationDegrees) < 0.01) return point;
  const rad = (rotationDegrees * Math.PI) / 180;
  const cos = Math.cos(rad);
  const sin = Math.sin(rad);
  const dx = point.x - center.x;
  const dy = point.y - center.y;
  return {
    x: center.x + dx * cos - dy * sin,
    y: center.y + dx * sin + dy * cos,
  };
}

export function resolveNodeAnchorWorldPoint(
  node: BoardNode,
  anchor: ConnectorAnchor,
  normalizedPoint: BoardPoint | null | undefined,
  otherCenter: BoardPoint,
): { point: BoardPoint; resolvedAnchor: Exclude<ConnectorAnchor, 'auto'>; isPinpoint: boolean } {
  const f = node.frame;
  const center: BoardPoint = { x: f.x + f.width * 0.5, y: f.y + f.height * 0.5 };

  if (normalizedPoint) {
    const nx = node.flipHorizontal ? 1 - normalizedPoint.x : normalizedPoint.x;
    const ny = node.flipVertical ? 1 - normalizedPoint.y : normalizedPoint.y;
    const localPt = {
      x: f.x + Math.max(0.02, Math.min(0.98, nx)) * f.width,
      y: f.y + Math.max(0.02, Math.min(0.98, ny)) * f.height,
    };
    const pt = rotateAroundCenter(localPt, center, node.rotationDegrees);
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
      rawPt = { x: center.x, y: f.y };
      break;
    case 'bottom':
      rawPt = { x: center.x, y: f.y + f.height };
      break;
    case 'leading':
      rawPt = { x: f.x, y: center.y };
      break;
    case 'trailing':
      rawPt = { x: f.x + f.width, y: center.y };
      break;
  }

  return {
    point: rotateAroundCenter(rawPt, center, node.rotationDegrees),
    resolvedAnchor: resolved,
    isPinpoint: false,
  };
}

function anchorNormal(anchor: Exclude<ConnectorAnchor, 'auto'>): BoardPoint {
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
}

export interface ConnectorPathGeometry {
  d: string;
  start: BoardPoint;
  end: BoardPoint;
  midpoint: BoardPoint;
  endAngleRad: number;
  toIsPinpoint: boolean;
  fromIsPinpoint: boolean;
}

export function buildConnectorGeometry(
  connector: Pick<
    BoardConnector,
    'fromAnchor' | 'toAnchor' | 'fromNormalizedPoint' | 'toNormalizedPoint' | 'style'
  >,
  fromNode: BoardNode,
  toNode: BoardNode,
): ConnectorPathGeometry {
  const fromCenter = {
    x: fromNode.frame.x + fromNode.frame.width * 0.5,
    y: fromNode.frame.y + fromNode.frame.height * 0.5,
  };
  const toCenter = {
    x: toNode.frame.x + toNode.frame.width * 0.5,
    y: toNode.frame.y + toNode.frame.height * 0.5,
  };

  const fromRes = resolveNodeAnchorWorldPoint(
    fromNode,
    connector.fromAnchor,
    connector.fromNormalizedPoint,
    toCenter,
  );
  const toRes = resolveNodeAnchorWorldPoint(
    toNode,
    connector.toAnchor,
    connector.toNormalizedPoint,
    fromCenter,
  );

  return buildConnectorPathPoints(
    fromRes.point,
    toRes.point,
    fromRes.resolvedAnchor,
    toRes.resolvedAnchor,
    connector.style,
    fromRes.isPinpoint,
    toRes.isPinpoint,
  );
}

export function buildConnectorPathPoints(
  start: BoardPoint,
  end: BoardPoint,
  fromAnchor: Exclude<ConnectorAnchor, 'auto'>,
  toAnchor: Exclude<ConnectorAnchor, 'auto'>,
  style: ConnectorStyle,
  fromIsPinpoint = false,
  toIsPinpoint = false,
): ConnectorPathGeometry {
  const dist = Math.hypot(end.x - start.x, end.y - start.y);

  if (style === 'straight') {
    const mid = { x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5 };
    const angle = Math.atan2(end.y - start.y, end.x - start.x);
    return {
      d: `M ${start.x.toFixed(1)} ${start.y.toFixed(1)} L ${end.x.toFixed(1)} ${end.y.toFixed(1)}`,
      start,
      end,
      midpoint: mid,
      endAngleRad: angle,
      toIsPinpoint,
      fromIsPinpoint,
    };
  }

  if (style === 'elbow') {
    const horizontalFirst = fromAnchor === 'leading' || fromAnchor === 'trailing';
    const midX = (start.x + end.x) * 0.5;
    const midY = (start.y + end.y) * 0.5;
    let d: string;
    let prevPt: BoardPoint;
    if (horizontalFirst) {
      d = `M ${start.x.toFixed(1)} ${start.y.toFixed(1)} L ${midX.toFixed(1)} ${start.y.toFixed(1)} L ${midX.toFixed(1)} ${end.y.toFixed(1)} L ${end.x.toFixed(1)} ${end.y.toFixed(1)}`;
      prevPt = { x: midX, y: end.y };
    } else {
      d = `M ${start.x.toFixed(1)} ${start.y.toFixed(1)} L ${start.x.toFixed(1)} ${midY.toFixed(1)} L ${end.x.toFixed(1)} ${midY.toFixed(1)} L ${end.x.toFixed(1)} ${end.y.toFixed(1)}`;
      prevPt = { x: end.x, y: midY };
    }
    const angle = Math.atan2(end.y - prevPt.y, end.x - prevPt.x);
    return {
      d,
      start,
      end,
      midpoint: { x: midX, y: midY },
      endAngleRad: Number.isFinite(angle) && (end.x !== prevPt.x || end.y !== prevPt.y) ? angle : Math.atan2(end.y - start.y, end.x - start.x),
      toIsPinpoint,
      fromIsPinpoint,
    };
  }

  // Curved cubic Bezier
  const tangent = Math.max(38, Math.min(180, dist * 0.36));
  const n1 = anchorNormal(fromAnchor);
  const n2 = anchorNormal(toAnchor);
  const cp1 = { x: start.x + n1.x * tangent, y: start.y + n1.y * tangent };
  const cp2 = { x: end.x + n2.x * tangent, y: end.y + n2.y * tangent };

  // Cubic Bezier midpoint at t = 0.5
  const mid = {
    x: 0.125 * start.x + 0.375 * cp1.x + 0.375 * cp2.x + 0.125 * end.x,
    y: 0.125 * start.y + 0.375 * cp1.y + 0.375 * cp2.y + 0.125 * end.y,
  };
  const endAngleRad = Math.atan2(end.y - cp2.y, end.x - cp2.x);

  return {
    d: `M ${start.x.toFixed(1)} ${start.y.toFixed(1)} C ${cp1.x.toFixed(1)} ${cp1.y.toFixed(1)}, ${cp2.x.toFixed(1)} ${cp2.y.toFixed(1)}, ${end.x.toFixed(1)} ${end.y.toFixed(1)}`,
    start,
    end,
    midpoint: mid,
    endAngleRad,
    toIsPinpoint,
    fromIsPinpoint,
  };
}

/**
 * Smooth quadratic midpoint SVG path for freehand InkStroke.
 */
export function buildInkStrokePath(points: readonly InkStrokePoint[]): string {
  if (points.length === 0) return '';
  if (points.length === 1) {
    const p = points[0];
    return `M ${p.x.toFixed(1)} ${p.y.toFixed(1)} L ${(p.x + 0.5).toFixed(1)} ${(p.y + 0.5).toFixed(1)}`;
  }
  const parts: string[] = [`M ${points[0].x.toFixed(1)} ${points[0].y.toFixed(1)}`];
  for (let i = 1; i < points.length - 1; i++) {
    const midX = (points[i].x + points[i + 1].x) * 0.5;
    const midY = (points[i].y + points[i + 1].y) * 0.5;
    parts.push(`Q ${points[i].x.toFixed(1)} ${points[i].y.toFixed(1)}, ${midX.toFixed(1)} ${midY.toFixed(1)}`);
  }
  const last = points[points.length - 1];
  parts.push(`L ${last.x.toFixed(1)} ${last.y.toFixed(1)}`);
  return parts.join(' ');
}

export function distancePointToSegment(p: BoardPoint, a: BoardPoint, b: BoardPoint): number {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const lenSq = dx * dx + dy * dy;
  if (lenSq < 1e-6) return Math.hypot(p.x - a.x, p.y - a.y);
  const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq));
  return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}

export function hitTestInkStroke(
  point: BoardPoint,
  strokePoints: readonly InkStrokePoint[],
  hitRadius: number,
): boolean {
  if (strokePoints.length === 0) return false;
  if (strokePoints.length === 1) {
    return Math.hypot(point.x - strokePoints[0].x, point.y - strokePoints[0].y) <= hitRadius;
  }
  for (let i = 0; i < strokePoints.length - 1; i++) {
    if (distancePointToSegment(point, strokePoints[i], strokePoints[i + 1]) <= hitRadius) {
      return true;
    }
  }
  return false;
}

/**
 * Re-tidies either the selected nodes (>= 2) or the entire board into crisp editorial alignment
 * while keeping the document strictly in Freeform mode. Supports all 3 editorial rhythm presets:
 * `balanced` (呼吸均衡), `magazine` (杂志主次), and `compact` (紧凑拼贴).
 */
export function tidyNodesWithStyle(
  document: MoodboardDocument,
  selectedNodeIDs: ReadonlySet<UUID>,
  assetsByID: Record<UUID, AssetRecord>,
  style: EditorialStyle = 'balanced',
): MoodboardDocument {
  if (style === 'balanced') {
    const tidied = tidyNodesInFreeform(document, selectedNodeIDs, assetsByID);
    return { ...tidied, mode: { type: 'freeform' } };
  }

  const targetNodes =
    selectedNodeIDs.size >= 2
      ? document.nodes.filter((n) => selectedNodeIDs.has(n.id))
      : document.nodes;
  if (targetNodes.length === 0) {
    return { ...document, mode: { type: 'freeform' } };
  }

  const minX = Math.min(...targetNodes.map((n) => rectMinX(n.frame)));
  const minY = Math.min(...targetNodes.map((n) => rectMinY(n.frame)));
  const maxX = Math.max(...targetNodes.map((n) => rectMaxX(n.frame)));
  const width = Math.max(760, Math.min(1440, maxX - minX + 56));
  const spacing = style === 'compact' ? 8 : 20;
  const columns = style === 'compact' ? 5 : 3;

  const solved = solveEditorialLayout(
    targetNodes,
    createDefaultAutoLayoutConfig({ columns, spacing, style }),
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

  return {
    ...document,
    mode: { type: 'freeform' },
    nodes,
  };
}
