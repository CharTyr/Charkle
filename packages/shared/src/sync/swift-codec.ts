import type {
  AssetRecord,
  AssetRichMetadata,
  FolderRecord,
  GitHubRepoMetadata,
  ISODateString,
  UUID,
} from '../models/core.js';
import type { AssetVector, EmbeddingPrecision } from '../models/media.js';
import type {
  AutoLayoutConfig,
  BoardConnector,
  BoardLayoutMode,
  BoardNode,
  BoardNodeKind,
  InkStroke,
  MoodboardDocument,
  NormalizedCropRect,
} from '../models/moodboard.js';
import type {
  AssetChanges,
  BoardChanges,
  CollectionChanges,
  SyncLogLine,
  SyncManifest,
  SyncOperation,
  SyncOperationChange,
} from '../models/sync.js';

/**
 * Seconds between Unix epoch (1970-01-01T00:00:00Z) and Apple Cocoa Reference Date (2001-01-01T00:00:00Z).
 * Swift's default `JSONEncoder().dateEncodingStrategy` (`.deferredToDate`) encodes `Date`
 * as a floating-point number of seconds relative to 2001-01-01T00:00:00Z.
 */
export const COCOA_REFERENCE_EPOCH_UNIX_SECONDS = 978_307_200;

export const ASSET_SYNC_EXCLUDED_FIELDS: ReadonlySet<string> = new Set([
  'id',
  'tags',
  'isLocalOriginalCached',
  'updatedAt',
  'updatedHLC',
]);

export const BOARD_SYNC_EXCLUDED_FIELDS: ReadonlySet<string> = new Set([
  'id',
  'nodes',
  'connectors',
  'inkStrokes',
  'updatedAt',
  'updatedHLC',
]);

// MARK: - Primitives: Dates, UUIDs, Base64, Canonical Sorted JSON

export function isoToCocoaSeconds(iso: ISODateString): number {
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) {
    throw new Error(`Invalid ISO date string: "${iso}"`);
  }
  return ms / 1000 - COCOA_REFERENCE_EPOCH_UNIX_SECONDS;
}

export function cocoaSecondsToIso(seconds: number): ISODateString {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds)) {
    throw new Error(`Invalid Cocoa reference date seconds: ${String(seconds)}`);
  }
  const unixMs = Math.round((seconds + COCOA_REFERENCE_EPOCH_UNIX_SECONDS) * 1000);
  return new Date(unixMs).toISOString();
}

function decodeWireDate(raw: unknown): ISODateString {
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    return cocoaSecondsToIso(raw);
  }
  if (typeof raw === 'string') {
    const ms = Date.parse(raw);
    if (Number.isFinite(ms)) return new Date(ms).toISOString();
  }
  throw new Error(`Expected Cocoa numeric timestamp or ISO date, got: ${JSON.stringify(raw)}`);
}

function decodeOptionalWireDate(raw: unknown): ISODateString | null {
  if (raw === undefined || raw === null) return null;
  return decodeWireDate(raw);
}

/**
 * Normalize UUID strings to Swift's canonical uppercase hyphenated representation.
 */
export function toSwiftUUID(id: UUID): UUID {
  return id.trim().toUpperCase();
}

// Pure cross-runtime (Node + Browser) UTF-8 <-> Base64 codec
const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const BASE64_LOOKUP = new Int16Array(128).fill(-1);
for (let i = 0; i < BASE64_ALPHABET.length; i++) {
  BASE64_LOOKUP[BASE64_ALPHABET.charCodeAt(i)] = i;
}

export function encodeBytesBase64(bytes: Uint8Array): string {
  let output = '';
  const len = bytes.length;
  for (let i = 0; i < len; i += 3) {
    const b0 = bytes[i];
    const b1 = i + 1 < len ? bytes[i + 1] : 0;
    const b2 = i + 2 < len ? bytes[i + 2] : 0;
    output += BASE64_ALPHABET[b0 >> 2];
    output += BASE64_ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)];
    output += i + 1 < len ? BASE64_ALPHABET[((b1 & 0x0f) << 2) | (b2 >> 6)] : '=';
    output += i + 2 < len ? BASE64_ALPHABET[b2 & 0x3f] : '=';
  }
  return output;
}

export function decodeBytesBase64(base64: string): Uint8Array {
  const cleaned = base64.replace(/\s+/g, '');
  if (cleaned.length === 0) return new Uint8Array(0);
  if (cleaned.length % 4 !== 0) {
    throw new Error('Invalid Base64 string length');
  }
  let padding = 0;
  if (cleaned.endsWith('==')) padding = 2;
  else if (cleaned.endsWith('=')) padding = 1;

  const byteLen = (cleaned.length / 4) * 3 - padding;
  const out = new Uint8Array(byteLen);
  let outIdx = 0;

  for (let i = 0; i < cleaned.length; i += 4) {
    const c0 = cleaned.charCodeAt(i);
    const c1 = cleaned.charCodeAt(i + 1);
    const c2 = cleaned.charCodeAt(i + 2);
    const c3 = cleaned.charCodeAt(i + 3);

    const v0 = c0 < 128 ? BASE64_LOOKUP[c0] : -1;
    const v1 = c1 < 128 ? BASE64_LOOKUP[c1] : -1;
    const v2 = c2 === 61 ? 0 : c2 < 128 ? BASE64_LOOKUP[c2] : -1;
    const v3 = c3 === 61 ? 0 : c3 < 128 ? BASE64_LOOKUP[c3] : -1;
    if (v0 < 0 || v1 < 0 || v2 < 0 || v3 < 0) {
      throw new Error('Invalid Base64 character');
    }

    const triple = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3;
    if (outIdx < byteLen) out[outIdx++] = (triple >> 16) & 0xff;
    if (outIdx < byteLen) out[outIdx++] = (triple >> 8) & 0xff;
    if (outIdx < byteLen) out[outIdx++] = triple & 0xff;
  }
  return out;
}

const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

export function encodeBase64Utf8(text: string): string {
  return encodeBytesBase64(utf8Encoder.encode(text));
}

export function decodeBase64Utf8(base64: string): string {
  return utf8Decoder.decode(decodeBytesBase64(base64));
}

function sortKeysDeep(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sortKeysDeep);
  }
  if (value !== null && typeof value === 'object') {
    const record = value as Record<string, unknown>;
    const keys = Object.keys(record).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    const sorted: Record<string, unknown> = {};
    for (const k of keys) {
      const v = record[k];
      if (v !== undefined) {
        sorted[k] = sortKeysDeep(v);
      }
    }
    return sorted;
  }
  return value;
}

/**
 * Produces deterministic sorted-key JSON without escaping slashes, matching Swift
 * `JSONEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`.
 */
export function canonicalSwiftJsonStringify(value: unknown): string {
  return JSON.stringify(sortKeysDeep(value));
}

function asRecord(raw: unknown, label: string): Record<string, unknown> {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new Error(`Expected JSON object for ${label}`);
  }
  return raw as Record<string, unknown>;
}

// MARK: - Swift Keyed-Enum Codecs: BoardLayoutMode & BoardNodeKind

export type SwiftBoardLayoutModeWire =
  | { autoEditorial: { _0: AutoLayoutConfig } }
  | { freeform: Record<string, never> };

export function encodeSwiftBoardLayoutMode(mode: BoardLayoutMode): SwiftBoardLayoutModeWire {
  if (mode.type === 'autoEditorial') {
    return {
      autoEditorial: {
        _0: {
          columns: mode.config.columns,
          showPaletteStrip: mode.config.showPaletteStrip,
          spacing: mode.config.spacing,
          style: mode.config.style,
        },
      },
    };
  }
  return { freeform: {} };
}

export function decodeSwiftBoardLayoutMode(raw: unknown): BoardLayoutMode {
  const obj = asRecord(raw, 'BoardLayoutMode');
  if ('autoEditorial' in obj) {
    const inner = asRecord(obj.autoEditorial, 'BoardLayoutMode.autoEditorial');
    const cfgRaw = asRecord(inner._0, 'BoardLayoutMode.autoEditorial._0');
    return {
      type: 'autoEditorial',
      config: {
        columns: typeof cfgRaw.columns === 'number' ? cfgRaw.columns : 4,
        spacing: typeof cfgRaw.spacing === 'number' ? cfgRaw.spacing : 16,
        style: (cfgRaw.style as AutoLayoutConfig['style']) ?? 'balanced',
        showPaletteStrip: typeof cfgRaw.showPaletteStrip === 'boolean' ? cfgRaw.showPaletteStrip : true,
      },
    };
  }
  if ('freeform' in obj) {
    return { type: 'freeform' };
  }
  throw new Error(`Unknown Swift BoardLayoutMode payload: ${JSON.stringify(raw)}`);
}

export function encodeSwiftBoardNodeKind(kind: BoardNodeKind): Record<string, unknown> {
  switch (kind.type) {
    case 'assetRef': {
      const payload: Record<string, unknown> = {
        assetID: toSwiftUUID(kind.assetID),
        autoplayLoop: kind.autoplayLoop,
        weight: kind.weight,
      };
      if (kind.crop != null) {
        payload.crop = kind.crop;
      }
      return { assetRef: payload };
    }
    case 'note': {
      const payload: Record<string, unknown> = {
        fontSize: kind.fontSize,
        style: kind.style,
        text: kind.text,
      };
      if (kind.title != null) {
        payload.title = kind.title;
      }
      return { note: payload };
    }
    case 'groupFrame':
      return {
        groupFrame: {
          tint: kind.tint,
          title: kind.title,
        },
      };
    case 'paletteStrip':
      return {
        paletteStrip: {
          autoSyncWithBoard: kind.autoSyncWithBoard,
          colors: kind.colors,
        },
      };
  }
}

export function decodeSwiftBoardNodeKind(raw: unknown): BoardNodeKind {
  const obj = asRecord(raw, 'BoardNodeKind');
  if ('assetRef' in obj) {
    const p = asRecord(obj.assetRef, 'BoardNodeKind.assetRef');
    return {
      type: 'assetRef',
      assetID: toSwiftUUID(String(p.assetID)),
      crop: (p.crop as NormalizedCropRect | null | undefined) ?? null,
      weight: typeof p.weight === 'number' ? p.weight : 1,
      autoplayLoop: Boolean(p.autoplayLoop),
    };
  }
  if ('note' in obj) {
    const p = asRecord(obj.note, 'BoardNodeKind.note');
    return {
      type: 'note',
      title: typeof p.title === 'string' ? p.title : null,
      text: String(p.text ?? ''),
      style: (p.style as Extract<BoardNodeKind, { type: 'note' }>['style']) ?? 'paper',
      fontSize: typeof p.fontSize === 'number' ? p.fontSize : 14,
    };
  }
  if ('groupFrame' in obj) {
    const p = asRecord(obj.groupFrame, 'BoardNodeKind.groupFrame');
    return {
      type: 'groupFrame',
      title: String(p.title ?? ''),
      tint: (p.tint as Extract<BoardNodeKind, { type: 'groupFrame' }>['tint']) ?? 'neutral',
    };
  }
  if ('paletteStrip' in obj) {
    const p = asRecord(obj.paletteStrip, 'BoardNodeKind.paletteStrip');
    return {
      type: 'paletteStrip',
      colors: Array.isArray(p.colors) ? p.colors : [],
      autoSyncWithBoard: Boolean(p.autoSyncWithBoard),
    };
  }
  throw new Error(`Unknown Swift BoardNodeKind payload: ${JSON.stringify(raw)}`);
}

// MARK: - Board Sub-Records & MoodboardDocument Codecs

export function encodeSwiftBoardNode(node: BoardNode): Record<string, unknown> {
  return {
    editorialOrder: node.editorialOrder,
    flipHorizontal: node.flipHorizontal,
    flipVertical: node.flipVertical,
    frame: node.frame,
    id: toSwiftUUID(node.id),
    isLocked: node.isLocked,
    kind: encodeSwiftBoardNodeKind(node.kind),
    rotationDegrees: node.rotationDegrees,
    updatedAt: isoToCocoaSeconds(node.updatedAt),
    zIndex: node.zIndex,
  };
}

export function decodeSwiftBoardNode(raw: unknown): BoardNode {
  const obj = asRecord(raw, 'BoardNode');
  return {
    id: toSwiftUUID(String(obj.id)),
    kind: decodeSwiftBoardNodeKind(obj.kind),
    frame: obj.frame as BoardNode['frame'],
    zIndex: typeof obj.zIndex === 'number' ? obj.zIndex : 0,
    rotationDegrees: typeof obj.rotationDegrees === 'number' ? obj.rotationDegrees : 0,
    flipHorizontal: typeof obj.flipHorizontal === 'boolean' ? obj.flipHorizontal : false,
    flipVertical: typeof obj.flipVertical === 'boolean' ? obj.flipVertical : false,
    isLocked: typeof obj.isLocked === 'boolean' ? obj.isLocked : false,
    editorialOrder: typeof obj.editorialOrder === 'number' ? obj.editorialOrder : 0,
    updatedAt: obj.updatedAt !== undefined ? decodeWireDate(obj.updatedAt) : new Date().toISOString(),
  };
}

export function encodeSwiftBoardConnector(connector: BoardConnector): Record<string, unknown> {
  const out: Record<string, unknown> = {
    colorHex: connector.colorHex,
    dashed: connector.dashed,
    fromAnchor: connector.fromAnchor,
    fromNodeID: toSwiftUUID(connector.fromNodeID),
    id: toSwiftUUID(connector.id),
    style: connector.style,
    toAnchor: connector.toAnchor,
    toNodeID: toSwiftUUID(connector.toNodeID),
    updatedAt: isoToCocoaSeconds(connector.updatedAt),
  };
  if (connector.fromNormalizedPoint != null) out.fromNormalizedPoint = connector.fromNormalizedPoint;
  if (connector.toNormalizedPoint != null) out.toNormalizedPoint = connector.toNormalizedPoint;
  if (connector.label != null) out.label = connector.label;
  return out;
}

export function decodeSwiftBoardConnector(raw: unknown): BoardConnector {
  const obj = asRecord(raw, 'BoardConnector');
  return {
    id: toSwiftUUID(String(obj.id)),
    fromNodeID: toSwiftUUID(String(obj.fromNodeID)),
    fromAnchor: (obj.fromAnchor as BoardConnector['fromAnchor']) ?? 'auto',
    fromNormalizedPoint: (obj.fromNormalizedPoint as BoardConnector['fromNormalizedPoint']) ?? null,
    toNodeID: toSwiftUUID(String(obj.toNodeID)),
    toAnchor: (obj.toAnchor as BoardConnector['toAnchor']) ?? 'auto',
    toNormalizedPoint: (obj.toNormalizedPoint as BoardConnector['toNormalizedPoint']) ?? null,
    label: typeof obj.label === 'string' ? obj.label : null,
    colorHex: typeof obj.colorHex === 'string' ? obj.colorHex : '#5C6672',
    style: (obj.style as BoardConnector['style']) ?? 'curved',
    dashed: typeof obj.dashed === 'boolean' ? obj.dashed : false,
    updatedAt: obj.updatedAt !== undefined ? decodeWireDate(obj.updatedAt) : new Date().toISOString(),
  };
}

export function encodeSwiftInkStroke(stroke: InkStroke): Record<string, unknown> {
  return {
    colorHex: stroke.colorHex,
    createdAt: isoToCocoaSeconds(stroke.createdAt),
    id: toSwiftUUID(stroke.id),
    lineWidth: stroke.lineWidth,
    opacity: stroke.opacity,
    points: stroke.points,
    zIndex: stroke.zIndex,
  };
}

export function decodeSwiftInkStroke(raw: unknown): InkStroke {
  const obj = asRecord(raw, 'InkStroke');
  return {
    id: toSwiftUUID(String(obj.id)),
    points: Array.isArray(obj.points) ? obj.points : [],
    colorHex: typeof obj.colorHex === 'string' ? obj.colorHex : '#E05A47',
    lineWidth: typeof obj.lineWidth === 'number' ? obj.lineWidth : 3.0,
    opacity: typeof obj.opacity === 'number' ? obj.opacity : 0.92,
    zIndex: typeof obj.zIndex === 'number' ? obj.zIndex : 1000,
    createdAt: obj.createdAt !== undefined ? decodeWireDate(obj.createdAt) : new Date().toISOString(),
  };
}

export function encodeSwiftMoodboardDocument(doc: MoodboardDocument): Record<string, unknown> {
  return {
    candidateAssetIDs: doc.candidateAssetIDs.map(toSwiftUUID),
    connectors: doc.connectors.map(encodeSwiftBoardConnector),
    createdAt: isoToCocoaSeconds(doc.createdAt),
    extractedPalette: doc.extractedPalette,
    id: toSwiftUUID(doc.id),
    inkStrokes: doc.inkStrokes.map(encodeSwiftInkStroke),
    mode: encodeSwiftBoardLayoutMode(doc.mode),
    nodes: doc.nodes.map(encodeSwiftBoardNode),
    pinnedOffline: doc.pinnedOffline,
    subtitle: doc.subtitle,
    title: doc.title,
    updatedAt: isoToCocoaSeconds(doc.updatedAt),
    updatedHLC: doc.updatedHLC,
    viewportCenter: doc.viewportCenter,
    viewportZoom: doc.viewportZoom,
  };
}

export function decodeSwiftMoodboardDocument(raw: unknown): MoodboardDocument {
  const obj = asRecord(raw, 'MoodboardDocument');
  return {
    id: toSwiftUUID(String(obj.id)),
    title: String(obj.title ?? ''),
    subtitle: String(obj.subtitle ?? ''),
    mode: decodeSwiftBoardLayoutMode(obj.mode),
    nodes: Array.isArray(obj.nodes) ? obj.nodes.map(decodeSwiftBoardNode) : [],
    connectors: Array.isArray(obj.connectors) ? obj.connectors.map(decodeSwiftBoardConnector) : [],
    inkStrokes: Array.isArray(obj.inkStrokes) ? obj.inkStrokes.map(decodeSwiftInkStroke) : [],
    extractedPalette: Array.isArray(obj.extractedPalette) ? obj.extractedPalette : [],
    candidateAssetIDs: Array.isArray(obj.candidateAssetIDs)
      ? obj.candidateAssetIDs.map((id) => toSwiftUUID(String(id)))
      : [],
    pinnedOffline: Boolean(obj.pinnedOffline),
    viewportCenter: (obj.viewportCenter as MoodboardDocument['viewportCenter']) ?? { x: 0, y: 0 },
    viewportZoom: typeof obj.viewportZoom === 'number' ? obj.viewportZoom : 1.0,
    createdAt: decodeWireDate(obj.createdAt),
    updatedAt: decodeWireDate(obj.updatedAt),
    updatedHLC: typeof obj.updatedHLC === 'number' ? obj.updatedHLC : 0,
  };
}

export function stringifySwiftMoodboardDocument(doc: MoodboardDocument): string {
  return canonicalSwiftJsonStringify(encodeSwiftMoodboardDocument(doc));
}

export function parseSwiftMoodboardDocument(json: string): MoodboardDocument {
  return decodeSwiftMoodboardDocument(JSON.parse(json));
}

// MARK: - Rich Metadata, AssetRecord, FolderRecord, AssetVector Codecs

export function encodeSwiftGitHubRepoMetadata(repo: GitHubRepoMetadata): Record<string, unknown> {
  const out: Record<string, unknown> = {
    defaultBranch: repo.defaultBranch,
    fetchedAt: isoToCocoaSeconds(repo.fetchedAt),
    forks: repo.forks,
    fullName: repo.fullName,
    owner: repo.owner,
    repo: repo.repo,
    stars: repo.stars,
    topics: repo.topics,
  };
  if (repo.ownerAvatarURL != null) out.ownerAvatarURL = repo.ownerAvatarURL;
  if (repo.description != null) out.description = repo.description;
  if (repo.watchers != null) out.watchers = repo.watchers;
  if (repo.language != null) out.language = repo.language;
  if (repo.licenseName != null) out.licenseName = repo.licenseName;
  if (repo.homepageURL != null) out.homepageURL = repo.homepageURL;
  if (repo.openGraphImageURL != null) out.openGraphImageURL = repo.openGraphImageURL;
  if (repo.readmeMarkdown != null) out.readmeMarkdown = repo.readmeMarkdown;
  return out;
}

export function decodeSwiftGitHubRepoMetadata(raw: unknown): GitHubRepoMetadata {
  const obj = asRecord(raw, 'GitHubRepoMetadata');
  return {
    owner: String(obj.owner),
    repo: String(obj.repo),
    fullName: String(obj.fullName),
    ownerAvatarURL: typeof obj.ownerAvatarURL === 'string' ? obj.ownerAvatarURL : null,
    description: typeof obj.description === 'string' ? obj.description : null,
    stars: typeof obj.stars === 'number' ? obj.stars : 0,
    forks: typeof obj.forks === 'number' ? obj.forks : 0,
    watchers: typeof obj.watchers === 'number' ? obj.watchers : null,
    language: typeof obj.language === 'string' ? obj.language : null,
    licenseName: typeof obj.licenseName === 'string' ? obj.licenseName : null,
    topics: Array.isArray(obj.topics) ? obj.topics.map(String) : [],
    defaultBranch: typeof obj.defaultBranch === 'string' ? obj.defaultBranch : 'main',
    homepageURL: typeof obj.homepageURL === 'string' ? obj.homepageURL : null,
    openGraphImageURL: typeof obj.openGraphImageURL === 'string' ? obj.openGraphImageURL : null,
    readmeMarkdown: typeof obj.readmeMarkdown === 'string' ? obj.readmeMarkdown : null,
    fetchedAt: decodeWireDate(obj.fetchedAt),
  };
}

export function encodeSwiftAssetRichMetadata(meta: AssetRichMetadata): Record<string, unknown> {
  const out: Record<string, unknown> = {
    isMarkdown: meta.isMarkdown,
  };
  if (meta.githubRepo != null) out.githubRepo = encodeSwiftGitHubRepoMetadata(meta.githubRepo);
  if (meta.socialPost != null) out.socialPost = meta.socialPost;
  if (meta.textExcerpt != null) out.textExcerpt = meta.textExcerpt;
  if (meta.model3DFormat != null) out.model3DFormat = meta.model3DFormat;
  return out;
}

export function decodeSwiftAssetRichMetadata(raw: unknown): AssetRichMetadata {
  const obj = asRecord(raw, 'AssetRichMetadata');
  return {
    githubRepo: obj.githubRepo != null ? decodeSwiftGitHubRepoMetadata(obj.githubRepo) : null,
    socialPost: (obj.socialPost as AssetRichMetadata['socialPost']) ?? null,
    textExcerpt: typeof obj.textExcerpt === 'string' ? obj.textExcerpt : null,
    isMarkdown: typeof obj.isMarkdown === 'boolean' ? obj.isMarkdown : false,
    model3DFormat: typeof obj.model3DFormat === 'string' ? obj.model3DFormat : null,
  };
}

export function encodeSwiftAssetRecord(asset: AssetRecord): Record<string, unknown> {
  const out: Record<string, unknown> = {
    contentHash: asset.contentHash,
    createdAt: isoToCocoaSeconds(asset.createdAt),
    dominantColors: asset.dominantColors,
    fileName: asset.fileName,
    fileSizeBytes: asset.fileSizeBytes,
    id: toSwiftUUID(asset.id),
    isLocalOriginalCached: asset.isLocalOriginalCached,
    isTrashed: asset.isTrashed,
    mediaKind: asset.mediaKind,
    mimeType: asset.mimeType,
    notes: asset.notes,
    pinnedOffline: asset.pinnedOffline,
    pixelHeight: asset.pixelHeight,
    pixelWidth: asset.pixelWidth,
    rating: asset.rating,
    suggestedTags: asset.suggestedTags,
    tags: asset.tags,
    title: asset.title,
    updatedAt: isoToCocoaSeconds(asset.updatedAt),
    updatedHLC: asset.updatedHLC,
    waveformPeaks: asset.waveformPeaks,
  };
  if (asset.folderID != null) out.folderID = toSwiftUUID(asset.folderID);
  if (asset.driveFileID != null) out.driveFileID = asset.driveFileID;
  if (asset.durationSeconds != null) out.durationSeconds = asset.durationSeconds;
  if (asset.sourceURL != null) out.sourceURL = asset.sourceURL;
  if (asset.sourceDomain != null) out.sourceDomain = asset.sourceDomain;
  if (asset.aiDescription != null) out.aiDescription = asset.aiDescription;
  if (asset.ocrText != null) out.ocrText = asset.ocrText;
  if (asset.lastOpenedAt != null) out.lastOpenedAt = isoToCocoaSeconds(asset.lastOpenedAt);
  if (asset.richMetadata != null) out.richMetadata = encodeSwiftAssetRichMetadata(asset.richMetadata);
  return out;
}

export function decodeSwiftAssetRecord(raw: unknown): AssetRecord {
  const obj = asRecord(raw, 'AssetRecord');
  return {
    id: toSwiftUUID(String(obj.id)),
    title: String(obj.title ?? ''),
    fileName: String(obj.fileName ?? ''),
    folderID: typeof obj.folderID === 'string' ? toSwiftUUID(obj.folderID) : null,
    driveFileID: typeof obj.driveFileID === 'string' ? obj.driveFileID : null,
    contentHash: String(obj.contentHash ?? ''),
    mediaKind: (obj.mediaKind as AssetRecord['mediaKind']) ?? 'image',
    mimeType: String(obj.mimeType ?? 'application/octet-stream'),
    fileSizeBytes: typeof obj.fileSizeBytes === 'number' ? obj.fileSizeBytes : 0,
    pixelWidth: typeof obj.pixelWidth === 'number' ? obj.pixelWidth : 0,
    pixelHeight: typeof obj.pixelHeight === 'number' ? obj.pixelHeight : 0,
    durationSeconds: typeof obj.durationSeconds === 'number' ? obj.durationSeconds : null,
    waveformPeaks: Array.isArray(obj.waveformPeaks) ? obj.waveformPeaks.map(Number) : [],
    sourceURL: typeof obj.sourceURL === 'string' ? obj.sourceURL : null,
    sourceDomain: typeof obj.sourceDomain === 'string' ? obj.sourceDomain : null,
    notes: String(obj.notes ?? ''),
    tags: Array.isArray(obj.tags) ? obj.tags.map(String) : [],
    suggestedTags: Array.isArray(obj.suggestedTags) ? obj.suggestedTags.map(String) : [],
    aiDescription: typeof obj.aiDescription === 'string' ? obj.aiDescription : null,
    ocrText: typeof obj.ocrText === 'string' ? obj.ocrText : null,
    dominantColors: Array.isArray(obj.dominantColors) ? obj.dominantColors : [],
    rating: typeof obj.rating === 'number' ? obj.rating : 0,
    pinnedOffline: Boolean(obj.pinnedOffline),
    isLocalOriginalCached: Boolean(obj.isLocalOriginalCached),
    isTrashed: Boolean(obj.isTrashed),
    createdAt: decodeWireDate(obj.createdAt),
    updatedAt: decodeWireDate(obj.updatedAt),
    updatedHLC: typeof obj.updatedHLC === 'number' ? obj.updatedHLC : 0,
    lastOpenedAt: decodeOptionalWireDate(obj.lastOpenedAt),
    richMetadata: obj.richMetadata != null ? decodeSwiftAssetRichMetadata(obj.richMetadata) : null,
  };
}

export function encodeSwiftFolderRecord(folder: FolderRecord): Record<string, unknown> {
  const out: Record<string, unknown> = {
    assetCount: folder.assetCount,
    createdAt: isoToCocoaSeconds(folder.createdAt),
    id: toSwiftUUID(folder.id),
    name: folder.name,
    sortOrder: folder.sortOrder,
    updatedAt: isoToCocoaSeconds(folder.updatedAt),
  };
  if (folder.parentID != null) out.parentID = toSwiftUUID(folder.parentID);
  if (folder.driveFolderID != null) out.driveFolderID = folder.driveFolderID;
  if (folder.colorHex != null) out.colorHex = folder.colorHex;
  if (folder.customSymbol != null) out.customSymbol = folder.customSymbol;
  return out;
}

export function decodeSwiftFolderRecord(raw: unknown): FolderRecord {
  const obj = asRecord(raw, 'FolderRecord');
  return {
    id: toSwiftUUID(String(obj.id)),
    name: String(obj.name ?? ''),
    parentID: typeof obj.parentID === 'string' ? toSwiftUUID(obj.parentID) : null,
    driveFolderID: typeof obj.driveFolderID === 'string' ? obj.driveFolderID : null,
    colorHex: typeof obj.colorHex === 'string' ? obj.colorHex : null,
    customSymbol: typeof obj.customSymbol === 'string' ? obj.customSymbol : null,
    sortOrder: typeof obj.sortOrder === 'number' ? obj.sortOrder : 0,
    assetCount: typeof obj.assetCount === 'number' ? obj.assetCount : 0,
    createdAt: decodeWireDate(obj.createdAt),
    updatedAt: decodeWireDate(obj.updatedAt),
  };
}

export function encodeSwiftAssetVector(vector: AssetVector): Record<string, unknown> {
  const out: Record<string, unknown> = {
    precision: vector.precision,
  };
  if (vector.featurePrint != null) out.featurePrint = vector.featurePrint;
  if (vector.embedding != null) out.embedding = vector.embedding;
  if (vector.embeddingModel != null) out.embeddingModel = vector.embeddingModel;
  return out;
}

export function decodeSwiftAssetVector(raw: unknown): AssetVector {
  const obj = asRecord(raw, 'AssetVector');
  const precision: EmbeddingPrecision = obj.precision === 32 ? 32 : 16;
  return {
    featurePrint: typeof obj.featurePrint === 'string' ? obj.featurePrint : null,
    embedding: Array.isArray(obj.embedding) ? obj.embedding.map(Number) : null,
    embeddingModel: typeof obj.embeddingModel === 'string' ? obj.embeddingModel : null,
    precision,
  };
}

// MARK: - Base64 SyncFields Codec (exact parity with Swift SyncFields.diff / merge)

export type SyncFieldEntity = 'asset' | 'board';

function encodeSingleSyncFieldToWireValue(
  entity: SyncFieldEntity,
  field: string,
  value: unknown,
): unknown {
  if (value === undefined || value === null) return null;

  if (entity === 'asset') {
    if (field === 'createdAt' || field === 'updatedAt' || field === 'lastOpenedAt') {
      return isoToCocoaSeconds(String(value));
    }
    if (field === 'id' || field === 'folderID') {
      return toSwiftUUID(String(value));
    }
    if (field === 'richMetadata') {
      return encodeSwiftAssetRichMetadata(value as AssetRichMetadata);
    }
    return value;
  }

  // entity === 'board'
  if (field === 'createdAt' || field === 'updatedAt') {
    return isoToCocoaSeconds(String(value));
  }
  if (field === 'id') {
    return toSwiftUUID(String(value));
  }
  if (field === 'candidateAssetIDs' && Array.isArray(value)) {
    return value.map((id) => toSwiftUUID(String(id)));
  }
  if (field === 'mode') {
    return encodeSwiftBoardLayoutMode(value as BoardLayoutMode);
  }
  return value;
}

function decodeSingleSyncFieldFromWireValue(
  entity: SyncFieldEntity,
  field: string,
  wireValue: unknown,
): unknown {
  if (wireValue === undefined || wireValue === null) return null;

  if (entity === 'asset') {
    if (field === 'createdAt' || field === 'updatedAt' || field === 'lastOpenedAt') {
      return decodeWireDate(wireValue);
    }
    if (field === 'id' || field === 'folderID') {
      return toSwiftUUID(String(wireValue));
    }
    if (field === 'richMetadata') {
      return decodeSwiftAssetRichMetadata(wireValue);
    }
    return wireValue;
  }

  // entity === 'board'
  if (field === 'createdAt' || field === 'updatedAt') {
    return decodeWireDate(wireValue);
  }
  if (field === 'id') {
    return toSwiftUUID(String(wireValue));
  }
  if (field === 'candidateAssetIDs' && Array.isArray(wireValue)) {
    return wireValue.map((id) => toSwiftUUID(String(id)));
  }
  if (field === 'mode') {
    return decodeSwiftBoardLayoutMode(wireValue);
  }
  return wireValue;
}

/**
 * Encodes a map of canonical Web field values into Swift `[String: Data]` (JSON Base64 strings),
 * where each value is Base64 of the canonical sorted-key Swift JSON fragment.
 */
export function encodeSwiftSyncFields(
  entity: SyncFieldEntity,
  fields: Record<string, unknown>,
): Record<string, string> {
  const result: Record<string, string> = {};
  for (const [field, value] of Object.entries(fields)) {
    const wireVal = encodeSingleSyncFieldToWireValue(entity, field, value);
    const jsonFragment = canonicalSwiftJsonStringify(wireVal);
    result[field] = encodeBase64Utf8(jsonFragment);
  }
  return result;
}

/**
 * Decodes Swift `[String: Data]` (Base64-encoded JSON fragments) back into canonical Web field values.
 */
export function decodeSwiftSyncFields(
  entity: SyncFieldEntity,
  wireFields: Record<string, string>,
): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [field, b64] of Object.entries(wireFields)) {
    const fragmentText = decodeBase64Utf8(b64);
    const parsed = JSON.parse(fragmentText) as unknown;
    result[field] = decodeSingleSyncFieldFromWireValue(entity, field, parsed);
  }
  return result;
}

/**
 * Computes field-level diff matching Swift `SyncFields.diff(_:_:excluding:)`.
 * Returns canonical Web values for every changed field (with `null` for cleared optional fields).
 */
export function diffSwiftSyncFields(
  entity: SyncFieldEntity,
  current: AssetRecord | MoodboardDocument,
  previous: AssetRecord | MoodboardDocument | null,
  excluding?: ReadonlySet<string>,
): Record<string, unknown> {
  const excluded =
    excluding ?? (entity === 'asset' ? ASSET_SYNC_EXCLUDED_FIELDS : BOARD_SYNC_EXCLUDED_FIELDS);
  const currentWire =
    entity === 'asset'
      ? encodeSwiftAssetRecord(current as AssetRecord)
      : encodeSwiftMoodboardDocument(current as MoodboardDocument);
  const previousWire =
    previous == null
      ? {}
      : entity === 'asset'
        ? encodeSwiftAssetRecord(previous as AssetRecord)
        : encodeSwiftMoodboardDocument(previous as MoodboardDocument);

  const keys = new Set([...Object.keys(currentWire), ...Object.keys(previousWire)]);
  const diff: Record<string, unknown> = {};
  for (const key of keys) {
    if (excluded.has(key)) continue;
    const newFrag = canonicalSwiftJsonStringify(key in currentWire ? currentWire[key] : null);
    const oldFrag = key in previousWire ? canonicalSwiftJsonStringify(previousWire[key]) : undefined;
    if (newFrag !== oldFrag) {
      const rawVal = key in currentWire ? currentWire[key] : null;
      diff[key] = decodeSingleSyncFieldFromWireValue(entity, key, rawVal);
    }
  }
  return diff;
}

// MARK: - SyncOperation, SyncLogLine, Ops JSONL & Manifest Codecs

function encodeCollectionChanges<T extends { id: UUID }>(
  changes: CollectionChanges<T>,
  encodeItem: (item: T) => Record<string, unknown>,
): Record<string, unknown> {
  return {
    removed: changes.removed.map(toSwiftUUID),
    updated: changes.updated.map(encodeItem),
  };
}

function decodeCollectionChanges<T extends { id: UUID }>(
  raw: unknown,
  decodeItem: (item: unknown) => T,
  label: string,
): CollectionChanges<T> {
  const obj = asRecord(raw, label);
  return {
    updated: Array.isArray(obj.updated) ? obj.updated.map(decodeItem) : [],
    removed: Array.isArray(obj.removed) ? obj.removed.map((id) => toSwiftUUID(String(id))) : [],
  };
}

export function encodeSwiftAssetChanges(delta: AssetChanges): Record<string, unknown> {
  return {
    fields: encodeSwiftSyncFields('asset', delta.fields),
    id: toSwiftUUID(delta.id),
    tagsAdded: delta.tagsAdded,
    tagsRemoved: delta.tagsRemoved,
  };
}

export function decodeSwiftAssetChanges(raw: unknown): AssetChanges {
  const obj = asRecord(raw, 'AssetChanges');
  const wireFields = asRecord(obj.fields ?? {}, 'AssetChanges.fields') as Record<string, string>;
  return {
    id: toSwiftUUID(String(obj.id)),
    fields: decodeSwiftSyncFields('asset', wireFields),
    tagsAdded: Array.isArray(obj.tagsAdded) ? obj.tagsAdded.map(String) : [],
    tagsRemoved: Array.isArray(obj.tagsRemoved) ? obj.tagsRemoved.map(String) : [],
  };
}

export function encodeSwiftBoardChanges(delta: BoardChanges): Record<string, unknown> {
  return {
    connectors: encodeCollectionChanges(delta.connectors, encodeSwiftBoardConnector),
    fields: encodeSwiftSyncFields('board', delta.fields),
    id: toSwiftUUID(delta.id),
    nodes: encodeCollectionChanges(delta.nodes, encodeSwiftBoardNode),
    strokes: encodeCollectionChanges(delta.strokes, encodeSwiftInkStroke),
  };
}

export function decodeSwiftBoardChanges(raw: unknown): BoardChanges {
  const obj = asRecord(raw, 'BoardChanges');
  const wireFields = asRecord(obj.fields ?? {}, 'BoardChanges.fields') as Record<string, string>;
  return {
    id: toSwiftUUID(String(obj.id)),
    fields: decodeSwiftSyncFields('board', wireFields),
    nodes: decodeCollectionChanges(obj.nodes, decodeSwiftBoardNode, 'BoardChanges.nodes'),
    connectors: decodeCollectionChanges(
      obj.connectors,
      decodeSwiftBoardConnector,
      'BoardChanges.connectors',
    ),
    strokes: decodeCollectionChanges(obj.strokes, decodeSwiftInkStroke, 'BoardChanges.strokes'),
  };
}

export function encodeSwiftSyncOperationChange(
  change: SyncOperationChange,
): Record<string, unknown> {
  switch (change.type) {
    case 'asset':
      return { asset: { _0: encodeSwiftAssetChanges(change.delta) } };
    case 'board':
      return { board: { _0: encodeSwiftBoardChanges(change.delta) } };
    case 'folder':
      return { folder: { _0: encodeSwiftFolderRecord(change.folder) } };
    case 'deleteAsset': {
      const payload: Record<string, unknown> = { _0: toSwiftUUID(change.id) };
      if (change.driveID != null) payload.driveID = change.driveID;
      return { deleteAsset: payload };
    }
    case 'deleteBoard':
      return { deleteBoard: { _0: toSwiftUUID(change.id) } };
    case 'deleteFolder': {
      const payload: Record<string, unknown> = { _0: toSwiftUUID(change.id) };
      if (change.driveID != null) payload.driveID = change.driveID;
      return { deleteFolder: payload };
    }
    case 'vector':
      return {
        vector: {
          _0: toSwiftUUID(change.id),
          _1: encodeSwiftAssetVector(change.vector),
        },
      };
  }
}

export function decodeSwiftSyncOperationChange(raw: unknown): SyncOperationChange {
  const obj = asRecord(raw, 'SyncOperation.Change');
  if ('asset' in obj) {
    const inner = asRecord(obj.asset, 'Change.asset');
    return { type: 'asset', delta: decodeSwiftAssetChanges(inner._0) };
  }
  if ('board' in obj) {
    const inner = asRecord(obj.board, 'Change.board');
    return { type: 'board', delta: decodeSwiftBoardChanges(inner._0) };
  }
  if ('folder' in obj) {
    const inner = asRecord(obj.folder, 'Change.folder');
    return { type: 'folder', folder: decodeSwiftFolderRecord(inner._0) };
  }
  if ('deleteAsset' in obj) {
    const inner = asRecord(obj.deleteAsset, 'Change.deleteAsset');
    return {
      type: 'deleteAsset',
      id: toSwiftUUID(String(inner._0)),
      driveID: typeof inner.driveID === 'string' ? inner.driveID : null,
    };
  }
  if ('deleteBoard' in obj) {
    const inner = asRecord(obj.deleteBoard, 'Change.deleteBoard');
    return {
      type: 'deleteBoard',
      id: toSwiftUUID(String(inner._0)),
    };
  }
  if ('deleteFolder' in obj) {
    const inner = asRecord(obj.deleteFolder, 'Change.deleteFolder');
    return {
      type: 'deleteFolder',
      id: toSwiftUUID(String(inner._0)),
      driveID: typeof inner.driveID === 'string' ? inner.driveID : null,
    };
  }
  if ('vector' in obj) {
    const inner = asRecord(obj.vector, 'Change.vector');
    return {
      type: 'vector',
      id: toSwiftUUID(String(inner._0)),
      vector: decodeSwiftAssetVector(inner._1),
    };
  }
  throw new Error(`Unknown Swift SyncOperation.Change payload: ${JSON.stringify(raw)}`);
}

export function encodeSwiftSyncOperation(op: SyncOperation): Record<string, unknown> {
  const out: Record<string, unknown> = {
    change: encodeSwiftSyncOperationChange(op.change),
    stamp: {
      device: op.stamp.device,
      time: op.stamp.time,
    },
  };
  if (op.projectLocation != null) {
    out.projectLocation = op.projectLocation;
  }
  return out;
}

export function decodeSwiftSyncOperation(raw: unknown): SyncOperation {
  const obj = asRecord(raw, 'SyncOperation');
  const stamp = asRecord(obj.stamp, 'SyncOperation.stamp');
  return {
    stamp: {
      time: Number(stamp.time),
      device: String(stamp.device),
    },
    change: decodeSwiftSyncOperationChange(obj.change),
    projectLocation: typeof obj.projectLocation === 'boolean' ? obj.projectLocation : null,
  };
}

export function encodeSwiftSyncLogLine(line: SyncLogLine): Record<string, unknown> {
  return {
    operation: encodeSwiftSyncOperation(line.operation),
    seq: line.seq,
  };
}

export function decodeSwiftSyncLogLine(raw: unknown): SyncLogLine {
  const obj = asRecord(raw, 'SyncLogLine');
  return {
    seq: Number(obj.seq),
    operation: decodeSwiftSyncOperation(obj.operation),
  };
}

export function encodeSwiftOpsJsonl(lines: readonly SyncLogLine[]): string {
  if (lines.length === 0) return '';
  return lines.map((line) => canonicalSwiftJsonStringify(encodeSwiftSyncLogLine(line))).join('\n') + '\n';
}

export function decodeSwiftOpsJsonl(content: string): SyncLogLine[] {
  const trimmed = content.trim();
  if (trimmed.length === 0) return [];
  return trimmed
    .split(/\r?\n/)
    .filter((line) => line.trim().length > 0)
    .map((line) => decodeSwiftSyncLogLine(JSON.parse(line)));
}

export function encodeSwiftManifest(manifest: SyncManifest): string {
  const out: Record<string, unknown> = {
    version: manifest.version,
  };
  if (manifest.rootFolderID != null) out.rootFolderID = manifest.rootFolderID;
  if (manifest.directories != null) out.directories = manifest.directories;
  return canonicalSwiftJsonStringify(out);
}

export function decodeSwiftManifest(json: string): SyncManifest {
  const obj = asRecord(JSON.parse(json), 'SyncManifest');
  if (typeof obj.version !== 'number') {
    throw new Error('SyncManifest missing numeric version');
  }
  return {
    version: obj.version,
    rootFolderID: typeof obj.rootFolderID === 'string' ? obj.rootFolderID : null,
    directories:
      obj.directories && typeof obj.directories === 'object' && !Array.isArray(obj.directories)
        ? (obj.directories as Record<string, string>)
        : null,
  };
}

const OPS_SHARD_RE = /^ops-([0-9a-fA-F]{32})-(\d+)\.jsonl$/;

/**
 * Parses a `.charkle/ops/ops-<device32hex>-<endSeq>.jsonl` filename.
 * Exact port of Swift `DriveSyncEngine.LogFile.init?(_:)`.
 */
export function parseOpsShardFileName(name: string): { device: string; endSeq: number } | null {
  const match = OPS_SHARD_RE.exec(name);
  if (!match) return null;
  const endSeq = Number.parseInt(match[2], 10);
  if (!Number.isSafeInteger(endSeq) || endSeq <= 0) return null;
  return { device: match[1], endSeq };
}

export function formatOpsShardFileName(device: string, endSeq: number): string {
  return `ops-${device}-${endSeq}.jsonl`;
}

export const SwiftWireCodec = {
  COCOA_REFERENCE_EPOCH_UNIX_SECONDS,
  ASSET_SYNC_EXCLUDED_FIELDS,
  BOARD_SYNC_EXCLUDED_FIELDS,
  isoToCocoaSeconds,
  cocoaSecondsToIso,
  toSwiftUUID,
  encodeBytesBase64,
  decodeBytesBase64,
  encodeBase64Utf8,
  decodeBase64Utf8,
  canonicalSwiftJsonStringify,
  encodeBoardLayoutMode: encodeSwiftBoardLayoutMode,
  decodeBoardLayoutMode: decodeSwiftBoardLayoutMode,
  encodeBoardNodeKind: encodeSwiftBoardNodeKind,
  decodeBoardNodeKind: decodeSwiftBoardNodeKind,
  encodeBoardNode: encodeSwiftBoardNode,
  decodeBoardNode: decodeSwiftBoardNode,
  encodeBoardConnector: encodeSwiftBoardConnector,
  decodeBoardConnector: decodeSwiftBoardConnector,
  encodeInkStroke: encodeSwiftInkStroke,
  decodeInkStroke: decodeSwiftInkStroke,
  encodeMoodboardDocument: encodeSwiftMoodboardDocument,
  decodeMoodboardDocument: decodeSwiftMoodboardDocument,
  stringifyMoodboardDocument: stringifySwiftMoodboardDocument,
  parseMoodboardDocument: parseSwiftMoodboardDocument,
  encodeAssetRecord: encodeSwiftAssetRecord,
  decodeAssetRecord: decodeSwiftAssetRecord,
  encodeFolderRecord: encodeSwiftFolderRecord,
  decodeFolderRecord: decodeSwiftFolderRecord,
  encodeAssetVector: encodeSwiftAssetVector,
  decodeAssetVector: decodeSwiftAssetVector,
  encodeSyncFields: encodeSwiftSyncFields,
  decodeSyncFields: decodeSwiftSyncFields,
  diffSyncFields: diffSwiftSyncFields,
  encodeSyncOperationChange: encodeSwiftSyncOperationChange,
  decodeSyncOperationChange: decodeSwiftSyncOperationChange,
  encodeSyncOperation: encodeSwiftSyncOperation,
  decodeSyncOperation: decodeSwiftSyncOperation,
  encodeSyncLogLine: encodeSwiftSyncLogLine,
  decodeSyncLogLine: decodeSwiftSyncLogLine,
  encodeOpsJsonl: encodeSwiftOpsJsonl,
  decodeOpsJsonl: decodeSwiftOpsJsonl,
  encodeManifest: encodeSwiftManifest,
  decodeManifest: decodeSwiftManifest,
  parseOpsShardFileName,
  formatOpsShardFileName,
} as const;
