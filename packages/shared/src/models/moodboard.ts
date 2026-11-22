import type { LabColor } from '../color/lab.js';
import type { ISODateString, ScoredAsset, UUID } from './core.js';

// MARK: - Geometry

export interface BoardPoint {
  x: number;
  y: number;
}

export const BOARD_POINT_ZERO: BoardPoint = { x: 0, y: 0 };

export interface BoardRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export function rectMinX(rect: BoardRect): number {
  return rect.x;
}
export function rectMinY(rect: BoardRect): number {
  return rect.y;
}
export function rectMaxX(rect: BoardRect): number {
  return rect.x + rect.width;
}
export function rectMaxY(rect: BoardRect): number {
  return rect.y + rect.height;
}
export function rectMidX(rect: BoardRect): number {
  return rect.x + rect.width * 0.5;
}
export function rectMidY(rect: BoardRect): number {
  return rect.y + rect.height * 0.5;
}

export interface NormalizedCropRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export const FULL_CROP_RECT: NormalizedCropRect = { x: 0, y: 0, width: 1, height: 1 };

/**
 * Construct from TypeSafe `Box` edges (`top`, `bottom`, `left`, `right` in `[0, 1]`, top-left origin).
 */
export function cropFromBoxEdges(
  top: number,
  bottom: number,
  left: number,
  right: number,
): NormalizedCropRect {
  const clampedLeft = Math.max(0.0, Math.min(1.0, left));
  const clampedRight = Math.max(clampedLeft, Math.min(1.0, right));
  const clampedTop = Math.max(0.0, Math.min(1.0, top));
  const clampedBottom = Math.max(clampedTop, Math.min(1.0, bottom));
  return {
    x: clampedLeft,
    y: clampedTop,
    width: Math.max(0.02, clampedRight - clampedLeft),
    height: Math.max(0.02, clampedBottom - clampedTop),
  };
}

export function cropArea(rect: NormalizedCropRect): number {
  return Math.max(0.0, rect.width) * Math.max(0.0, rect.height);
}

export function cropCenterPoint(rect: NormalizedCropRect): BoardPoint {
  return {
    x: Math.max(0.0, Math.min(1.0, rect.x + rect.width * 0.5)),
    y: Math.max(0.0, Math.min(1.0, rect.y + rect.height * 0.5)),
  };
}

export function isMeaningfulCropSubregion(rect: NormalizedCropRect): boolean {
  return rect.width >= 0.04 && rect.height >= 0.04 && cropArea(rect) < 0.96;
}

export function clampCropRect(rect: NormalizedCropRect): NormalizedCropRect {
  const left = Math.max(0.0, Math.min(0.98, rect.x));
  const top = Math.max(0.0, Math.min(0.98, rect.y));
  const right = Math.max(left + 0.02, Math.min(1.0, rect.x + rect.width));
  const bottom = Math.max(top + 0.02, Math.min(1.0, rect.y + rect.height));
  return { x: left, y: top, width: right - left, height: bottom - top };
}

export function padCropRect(rect: NormalizedCropRect, fraction: number): NormalizedCropRect {
  const pad = Math.max(0.0, Math.min(0.35, fraction));
  const left = Math.max(0.0, rect.x - pad);
  const top = Math.max(0.0, rect.y - pad);
  const right = Math.min(1.0, rect.x + rect.width + pad);
  const bottom = Math.min(1.0, rect.y + rect.height + pad);
  return {
    x: left,
    y: top,
    width: Math.max(0.02, right - left),
    height: Math.max(0.02, bottom - top),
  };
}

export function mapImagePointToVisibleCrop(
  crop: NormalizedCropRect,
  point: BoardPoint,
): BoardPoint {
  if (crop.width <= 0.01 || crop.height <= 0.01) return point;
  const vx = (point.x - crop.x) / crop.width;
  const vy = (point.y - crop.y) / crop.height;
  return {
    x: Math.max(0.02, Math.min(0.98, vx)),
    y: Math.max(0.02, Math.min(0.98, vy)),
  };
}

// MARK: - Editorial & Layout Modes

export type EditorialStyle = 'balanced' | 'magazine' | 'compact';

export const EDITORIAL_STYLES: readonly EditorialStyle[] = [
  'balanced',
  'magazine',
  'compact',
] as const;

export function editorialStyleLocalizedLabel(style: EditorialStyle): string {
  switch (style) {
    case 'balanced':
      return '呼吸均衡';
    case 'magazine':
      return '杂志主次';
    case 'compact':
      return '紧凑拼贴';
  }
}

export interface AutoLayoutConfig {
  columns: number;
  spacing: number;
  style: EditorialStyle;
  showPaletteStrip: boolean;
}

export function createDefaultAutoLayoutConfig(
  overrides: Partial<AutoLayoutConfig> = {},
): AutoLayoutConfig {
  return {
    columns: 4,
    spacing: 16,
    style: 'balanced',
    showPaletteStrip: true,
    ...overrides,
  };
}

export type BoardLayoutMode =
  | { type: 'autoEditorial'; config: AutoLayoutConfig }
  | { type: 'freeform' };

export function isAutoEditorialMode(
  mode: BoardLayoutMode,
): mode is { type: 'autoEditorial'; config: AutoLayoutConfig } {
  return mode.type === 'autoEditorial';
}

// MARK: - Nodes, Connectors & Ink

export type NoteStyle = 'paper' | 'ink' | 'warm' | 'sage' | 'slate';

export const NOTE_STYLES: readonly NoteStyle[] = ['paper', 'ink', 'warm', 'sage', 'slate'] as const;

export type GroupTint = 'neutral' | 'sand' | 'sage' | 'slate' | 'terracotta' | 'ocean';

export const GROUP_TINTS: readonly GroupTint[] = [
  'neutral',
  'sand',
  'sage',
  'slate',
  'terracotta',
  'ocean',
] as const;

export type BoardNodeKind =
  | {
      type: 'assetRef';
      assetID: UUID;
      crop?: NormalizedCropRect | null;
      weight: number;
      autoplayLoop: boolean;
    }
  | {
      type: 'note';
      title?: string | null;
      text: string;
      style: NoteStyle;
      fontSize: number;
    }
  | {
      type: 'groupFrame';
      title: string;
      tint: GroupTint;
    }
  | {
      type: 'paletteStrip';
      colors: LabColor[];
      autoSyncWithBoard: boolean;
    };

export interface BoardNode {
  id: UUID;
  kind: BoardNodeKind;
  frame: BoardRect;
  zIndex: number;
  rotationDegrees: number;
  flipHorizontal: boolean;
  flipVertical: boolean;
  isLocked: boolean;
  editorialOrder: number;
  updatedAt: ISODateString;
}

export function getReferencedAssetID(node: Pick<BoardNode, 'kind'>): UUID | null {
  return node.kind.type === 'assetRef' ? node.kind.assetID : null;
}

export type ConnectorAnchor = 'auto' | 'top' | 'bottom' | 'leading' | 'trailing';

export type ConnectorStyle = 'curved' | 'elbow' | 'straight';

export interface BoardConnector {
  id: UUID;
  fromNodeID: UUID;
  fromAnchor: ConnectorAnchor;
  fromNormalizedPoint?: BoardPoint | null;
  toNodeID: UUID;
  toAnchor: ConnectorAnchor;
  toNormalizedPoint?: BoardPoint | null;
  label?: string | null;
  colorHex: string;
  style: ConnectorStyle;
  dashed: boolean;
  updatedAt: ISODateString;
}

export interface InkStrokePoint {
  x: number;
  y: number;
  pressure: number;
}

export interface InkStroke {
  id: UUID;
  points: InkStrokePoint[];
  colorHex: string;
  lineWidth: number;
  opacity: number;
  zIndex: number;
  createdAt: ISODateString;
}

// MARK: - Moodboard Document & Summary

export interface MoodboardDocument {
  id: UUID;
  title: string;
  subtitle: string;
  mode: BoardLayoutMode;
  nodes: BoardNode[];
  connectors: BoardConnector[];
  inkStrokes: InkStroke[];
  extractedPalette: LabColor[];
  candidateAssetIDs: UUID[];
  pinnedOffline: boolean;
  viewportCenter: BoardPoint;
  viewportZoom: number;
  createdAt: ISODateString;
  updatedAt: ISODateString;
  updatedHLC: number;
}

export function getBoardReferencedAssetIDs(doc: Pick<MoodboardDocument, 'nodes'>): UUID[] {
  const ids: UUID[] = [];
  for (const node of doc.nodes) {
    if (node.kind.type === 'assetRef') {
      ids.push(node.kind.assetID);
    }
  }
  return ids;
}

export function createDefaultMoodboardDocument(
  overrides: Partial<MoodboardDocument> & Pick<MoodboardDocument, 'id' | 'title'>,
): MoodboardDocument {
  const now = new Date().toISOString();
  return {
    subtitle: '',
    mode: { type: 'autoEditorial', config: createDefaultAutoLayoutConfig() },
    nodes: [],
    connectors: [],
    inkStrokes: [],
    extractedPalette: [],
    candidateAssetIDs: [],
    pinnedOffline: false,
    viewportCenter: { ...BOARD_POINT_ZERO },
    viewportZoom: 1.0,
    createdAt: now,
    updatedAt: now,
    updatedHLC: 0,
    ...overrides,
  };
}

export interface MoodboardSummary {
  id: UUID;
  title: string;
  subtitle: string;
  mode: BoardLayoutMode;
  itemCount: number;
  previewAssetIDs: UUID[];
  paletteHexes: string[];
  pinnedOffline: boolean;
  updatedAt: ISODateString;
}

// MARK: - Moodboard Agent & Curation

export type MoodboardSeed =
  | { type: 'prompt'; prompt: string }
  | { type: 'seedAssets'; assetIDs: UUID[] }
  | { type: 'palette'; colors: LabColor[]; tolerance: number }
  | { type: 'manualSelection'; assetIDs: UUID[] }
  | { type: 'combined'; prompt?: string | null; seedAssetIDs: UUID[]; palette: LabColor[] };

export type MoodboardAgentPhase =
  | 'planning'
  | 'retrieving'
  | 'inspectingVisuals'
  | 'composing'
  | 'verifying'
  | 'repairing'
  | 'completed'
  | 'fallbackOffline';

export type MoodboardAgentStepStatus = 'running' | 'done' | 'warning';

export interface MoodboardAgentStep {
  id: UUID;
  phase: MoodboardAgentPhase;
  title: string;
  detail: string;
  status: MoodboardAgentStepStatus;
  timestamp: ISODateString;
}

export interface MoodboardSectionDraft {
  id: UUID;
  title: string;
  tint: GroupTint;
  rationale: string;
  assetIDs: UUID[];
  heroAssetIDs: UUID[];
}

export interface MoodboardCurationRequest {
  prompt: string;
  seedAssetIDs: UUID[];
  scopeFolderIDs: UUID[];
  requiredTags: string[];
  targetPalette: LabColor[];
  colorTolerance: number;
  preferredCount: number;
  candidateCount: number;
  layoutStyle: EditorialStyle;
  useFreeformLayout: boolean;
  includeCuratorNotes: boolean;
  excludedAssetIDs: UUID[];
  lockedAssetIDs: UUID[];
  existingBoard?: MoodboardDocument | null;
  refinementInstruction?: string | null;
  autoFocusDetailCrop: boolean;
}

export function createDefaultMoodboardCurationRequest(
  overrides: Partial<MoodboardCurationRequest> = {},
): MoodboardCurationRequest {
  return {
    prompt: '',
    seedAssetIDs: [],
    scopeFolderIDs: [],
    requiredTags: [],
    targetPalette: [],
    colorTolerance: 28.0,
    preferredCount: 12,
    candidateCount: 24,
    layoutStyle: 'magazine',
    useFreeformLayout: false,
    includeCuratorNotes: true,
    excludedAssetIDs: [],
    lockedAssetIDs: [],
    existingBoard: null,
    refinementInstruction: null,
    autoFocusDetailCrop: false,
    ...overrides,
  };
}

export interface MoodboardProposal {
  draftDocument: MoodboardDocument;
  primaryMatches: ScoredAsset[];
  candidatePool: ScoredAsset[];
  extractedPalette: LabColor[];
  usedCloudAI: boolean;
  curatedSummary: string;
  agentTrace: MoodboardAgentStep[];
  sections: MoodboardSectionDraft[];
  rejectedSummary?: string | null;
  cachedVisualInsightsCount: number;
}

// MARK: - Moodboard Export

export type MoodboardExportFormat = 'png' | 'jpeg';

export interface MoodboardExportOptions {
  scale: number;
  includeAnnotations: boolean;
  includePaletteStrip: boolean;
  darkAppearance: boolean;
  padding: number;
}

export function createDefaultMoodboardExportOptions(
  overrides: Partial<MoodboardExportOptions> = {},
): MoodboardExportOptions {
  return {
    scale: 2.0,
    includeAnnotations: true,
    includePaletteStrip: true,
    darkAppearance: false,
    padding: 40,
    ...overrides,
  };
}
