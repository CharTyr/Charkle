//! 1:1 TypeScript mirrors of `charkle-core` wire contracts and `charkle-platform-win` window types.

export const COCOA_EPOCH_OFFSET_SEC = 978_307_200;

/** Wire timestamp emitted by Rust `cocoa_date` (seconds since 2001-01-01T00:00:00Z) or ISO string. */
export type WireDate = number | string;

export function wireDateToMs(value: WireDate | null | undefined): number {
  if (value == null) return 0;
  if (typeof value === 'number') {
    return Math.round((value + COCOA_EPOCH_OFFSET_SEC) * 1000);
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

export function msToCocoaSeconds(ms: number): number {
  return ms / 1000 - COCOA_EPOCH_OFFSET_SEC;
}

export function formatWireDate(value: WireDate | null | undefined): string {
  const ms = wireDateToMs(value);
  if (!ms) return '—';
  const d = new Date(ms);
  return d.toLocaleDateString('zh-CN', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  });
}

export type MediaKind =
  | 'image'
  | 'animatedImage'
  | 'video'
  | 'audio'
  | 'document'
  | 'webBookmark'
  | 'designFile'
  | 'model3D';

export type AspectShape = 'landscape' | 'portrait' | 'square' | 'ultrawide';

export type SortOrder =
  | 'newest'
  | 'oldest'
  | 'nameAsc'
  | 'ratingDesc'
  | 'fileSizeDesc'
  | 'relevance';

export type GalleryLayoutMode =
  | 'verticalMasonry'
  | 'horizontalJustified'
  | 'galleryFilmstrip';

export type SocialPlatform = 'x' | 'threads' | 'bluesky';
export type SocialMediaAttachmentKind = 'photo' | 'video' | 'gif';
export type SmartFolderMatchMode = 'all' | 'any';
export type NoteStyle = 'paper' | 'ink' | 'warm' | 'sage' | 'slate';
export type GroupTint = 'neutral' | 'sand' | 'sage' | 'slate' | 'terracotta' | 'ocean';
export type ThumbnailTier = 'grid520' | 'preview1400';

export interface LabColor {
  hex: string;
  l: number;
  a: number;
  b: number;
  proportion: number;
}

export interface GitHubRepoMetadata {
  owner: string;
  repo: string;
  fullName: string;
  description?: string | null;
  language?: string | null;
  stars: number;
  forks: number;
  openIssues: number;
  license?: string | null;
  topics: string[];
  homepageURL?: string | null;
  defaultBranch?: string | null;
  avatarURL?: string | null;
  openGraphImageURL?: string | null;
  readmeMarkdown?: string | null;
  fetchedAt?: WireDate | null;
}

export interface SocialMediaAttachment {
  id: string;
  kind: SocialMediaAttachmentKind;
  url: string;
  thumbnailURL?: string | null;
}

export interface SocialPostMetadata {
  platform: SocialPlatform;
  authorName: string;
  authorHandle: string;
  authorAvatarURL?: string | null;
  publishedAtText?: string | null;
  bodyText: string;
  quotedAuthor?: string | null;
  quotedText?: string | null;
  articleTitle?: string | null;
  mediaURLs: string[];
  mediaThumbnailURLs: string[];
  attachments: SocialMediaAttachment[];
  hasVideo: boolean;
  videoURL?: string | null;
  replyCount?: number | null;
  repostCount?: number | null;
  likeCount?: number | null;
  viewCount?: number | null;
  originalURL: string;
  mediaFetchFailed?: boolean;
}

export interface PhotoExifMetadata {
  cameraMake?: string | null;
  cameraModel?: string | null;
  lensModel?: string | null;
  capturedAt?: string | null;
  exposureTime?: string | null;
  fNumber?: number | null;
  iso?: number | null;
  focalLengthMM?: number | null;
  focalLength35mm?: number | null;
  exposureBiasEV?: number | null;
  meteringMode?: string | null;
  flashFired?: boolean | null;
  whiteBalance?: string | null;
  colorProfile?: string | null;
  bitDepth?: number | null;
  dpiWidth?: number | null;
  dpiHeight?: number | null;
  software?: string | null;
  artist?: string | null;
  copyright?: string | null;
  latitude?: number | null;
  longitude?: number | null;
}

export interface AIGenerationMetadata {
  generator?: string | null;
  prompt?: string | null;
  negativePrompt?: string | null;
  modelName?: string | null;
  modelHash?: string | null;
  sampler?: string | null;
  scheduler?: string | null;
  steps?: number | null;
  cfgScale?: number | null;
  seed?: string | null;
  sizeText?: string | null;
  clipSkip?: number | null;
  loras: string[];
  extraParameters: Record<string, string>;
  rawParameters?: string | null;
}

export interface AssetRichMetadata {
  githubRepo?: GitHubRepoMetadata | null;
  socialPost?: SocialPostMetadata | null;
  photoExif?: PhotoExifMetadata | null;
  aiGeneration?: AIGenerationMetadata | null;
  textExcerpt?: string | null;
  isMarkdown?: boolean;
  model3DFormat?: string | null;
}

export interface AssetRecord {
  id: string;
  driveFileID?: string | null;
  contentHash: string;
  folderID?: string | null;
  mediaKind: MediaKind;
  mimeType: string;
  title: string;
  fileName: string;
  notes: string;
  tags: string[];
  suggestedTags: string[];
  rating: number;
  pixelWidth: number;
  pixelHeight: number;
  durationSeconds?: number | null;
  fileSizeBytes: number;
  dominantColors: LabColor[];
  waveformPeaks: number[];
  sourceURL?: string | null;
  sourceDomain?: string | null;
  ocrText?: string | null;
  aiDescription?: string | null;
  richMetadata?: AssetRichMetadata | null;
  pinnedOffline: boolean;
  isLocalOriginalCached: boolean;
  isTrashed: boolean;
  createdAt: WireDate;
  updatedAt: WireDate;
  lastOpenedAt?: WireDate | null;
  updatedHLC: number;
}

export interface FolderRecord {
  id: string;
  driveFolderID?: string | null;
  name: string;
  parentID?: string | null;
  sortOrder: number;
  assetCount: number;
  colorHex?: string | null;
  customSymbol?: string | null;
  createdAt: WireDate;
  updatedAt: WireDate;
}

export interface SmartFolderRule {
  matchMode: SmartFolderMatchMode;
  tags: string[];
  descriptionQuery: string;
  colorHexes: string[];
  colorTolerance: number;
  mediaKinds: MediaKind[];
  minRating: number;
}

export interface SmartFolderRecord {
  id: string;
  name: string;
  colorHex?: string | null;
  rule: SmartFolderRule;
  sortOrder: number;
  createdAt: WireDate;
  updatedAt: WireDate;
}

export interface TagCount {
  name: string;
  count: number;
}

export interface FilterCriteria {
  searchQuery: string;
  kinds: MediaKind[];
  selectedColorHex: string | null;
  colorTolerance: number;
  shape: AspectShape | null;
  minRating: number;
  tags: string[];
  folderID: string | null;
  includeSubfolders: boolean;
  onlyInbox: boolean;
  onlyUntagged: boolean;
  onlyRecentDays: number | null;
  onlyPinnedOffline: boolean;
  includeTrashed: boolean;
  onlyTrashed: boolean;
  sortBy: SortOrder;
}

export function createDefaultFilterCriteria(
  overrides: Partial<FilterCriteria> = {},
): FilterCriteria {
  return {
    searchQuery: '',
    kinds: [],
    selectedColorHex: null,
    colorTolerance: 28,
    shape: null,
    minRating: 0,
    tags: [],
    folderID: null,
    includeSubfolders: false,
    onlyInbox: false,
    onlyUntagged: false,
    onlyRecentDays: null,
    onlyPinnedOffline: false,
    includeTrashed: false,
    onlyTrashed: false,
    sortBy: 'newest',
    ...overrides,
  };
}

export type FolderAssignment = 'unchanged' | 'inbox' | { folder: string };

export interface AssetBatchPatch {
  assetIDs: string[];
  title?: string | null;
  notes?: string | null;
  rating?: number | null;
  addTags?: string[];
  removeTags?: string[];
  acceptSuggestedTags?: boolean;
  dismissSuggestedTags?: string[];
  folderAssignment?: FolderAssignment;
  pinnedOffline?: boolean | null;
  isTrashed?: boolean | null;
}

export type QuickJumpKind = 'folder' | 'moodboard' | 'tag' | 'asset';

export interface QuickJumpMatch {
  id: string;
  kind: QuickJumpKind;
  title: string;
  subtitle: string;
  targetUUID?: string | null;
  tagName?: string | null;
  score: number;
}

export interface ScoredAsset {
  asset: AssetRecord;
  score: number;
  matchReasons: string[];
}

export interface FolderSuggestion {
  folderID: string;
  folderName: string;
  confidence: number;
  reason: string;
}

export interface MoodboardSummary {
  id: string;
  title: string;
  subtitle: string;
  itemCount: number;
  previewAssetIDs: string[];
  paletteHexes: string[];
  pinnedOffline: boolean;
  updatedAt: WireDate;
}

export interface MoodboardDocument {
  id: string;
  title: string;
  subtitle: string;
  mode: unknown;
  nodes: Array<{
    id: string;
    kind: unknown;
    frame: { x: number; y: number; width: number; height: number };
    zIndex: number;
    rotationDegrees: number;
    flipHorizontal: boolean;
    flipVertical: boolean;
    isLocked: boolean;
    editorialOrder: number;
    updatedAt: WireDate;
  }>;
  connectors: unknown[];
  inkStrokes: unknown[];
  extractedPalette: LabColor[];
  candidateAssetIDs: string[];
  pinnedOffline: boolean;
  viewportCenter: { x: number; y: number };
  viewportZoom: number;
  createdAt: WireDate;
  updatedAt: WireDate;
  updatedHLC: number;
}

export type DriveTransportMode =
  | 'directAPIWithGDirect'
  | 'webDAV'
  | 'gdirectMount'
  | 'localOnly';

export interface DriveSyncConfig {
  mode: DriveTransportMode;
  rootFolderName: string;
  sharedFolderURLOrID: string;
  mountPath: string;
  selectedGDirectAccount?: string | null;
  useGDirectIPAcceleration: boolean;
  webDAVServerURL: string;
  webDAVUsername: string;
  webDAVRemotePath: string;
  localLibraryPath: string;
  autoSyncIntervalSeconds: number;
  syncThumbnails: boolean;
  syncEmbeddings: boolean;
}

export interface DriveAccountInfo {
  email: string;
  displayName?: string | null;
  storageUsedBytes?: number | null;
  storageLimitBytes?: number | null;
  source: string;
}

export type SyncPhase =
  | 'idle'
  | 'scanning'
  | 'merging'
  | { uploading: { completed: number; total: number } }
  | { downloading: { completed: number; total: number } }
  | { error: string };

export interface SyncStatus {
  phase: SyncPhase;
  lastSyncedAt?: WireDate | null;
  pendingOpCount: number;
  account?: DriveAccountInfo | null;
  activeMode: DriveTransportMode;
  lastError?: string | null;
  currentDetail?: string | null;
  progressFraction?: number | null;
}

export interface SyncReport {
  uploadedOps: number;
  downloadedOps: number;
  discoveredRemoteAssets: number;
  discoveredAssetIDs: string[];
  updatedBoards: number;
  reconciledRenames: number;
  durationSeconds: number;
}

export interface CacheStats {
  thumbnailBytes: number;
  originalCacheBytes: number;
  pinnedOfflineBytes: number;
  budgetBytes: number;
  cachedOriginalCount: number;
  pinnedAssetCount: number;
}

export type BackdropKind = 'mica' | 'solidFallback';

export interface WindowSurfaceState {
  buildNumber: number;
  backdrop: BackdropKind;
  isDark: boolean;
  transparencyEnabled: boolean;
  animationsEnabled: boolean;
  snapLayoutsSupported: boolean;
}

export interface ClientRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type SidebarDestination =
  | { type: 'allItems' }
  | { type: 'inbox' }
  | { type: 'moodboardsHome' }
  | { type: 'moodboard'; id: string }
  | { type: 'untagged' }
  | { type: 'recent' }
  | { type: 'trash' }
  | { type: 'folder'; id: string }
  | { type: 'smartFolder'; id: string }
  | { type: 'tag'; name: string };

export interface FolderTreeNode {
  folder: FolderRecord;
  depth: number;
  children: FolderTreeNode[];
  totalAssetCount: number;
}

export function buildFolderTree(folders: FolderRecord[]): FolderTreeNode[] {
  const byParent = new Map<string | null, FolderRecord[]>();
  const idSet = new Set(folders.map((f) => f.id));

  for (const f of folders) {
    const pid = f.parentID && idSet.has(f.parentID) ? f.parentID : null;
    const list = byParent.get(pid) ?? [];
    list.push(f);
    byParent.set(pid, list);
  }

  for (const list of byParent.values()) {
    list.sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name));
  }

  const visited = new Set<string>();
  const walk = (parentId: string | null, depth: number): FolderTreeNode[] => {
    const items = byParent.get(parentId) ?? [];
    const out: FolderTreeNode[] = [];
    for (const folder of items) {
      if (visited.has(folder.id)) continue;
      visited.add(folder.id);
      const children = walk(folder.id, depth + 1);
      const childSum = children.reduce((acc, c) => acc + c.totalAssetCount, 0);
      out.push({
        folder,
        depth,
        children,
        totalAssetCount: folder.assetCount + childSum,
      });
    }
    return out;
  };

  return walk(null, 0);
}

export function flattenFolderTree(nodes: FolderTreeNode[]): FolderTreeNode[] {
  const result: FolderTreeNode[] = [];
  const visit = (list: FolderTreeNode[]) => {
    for (const n of list) {
      result.push(n);
      visit(n.children);
    }
  };
  visit(nodes);
  return result;
}

export function mediaKindLabel(kind: MediaKind): string {
  switch (kind) {
    case 'image':
      return '图片';
    case 'animatedImage':
      return '动图';
    case 'video':
      return '视频';
    case 'audio':
      return '音频';
    case 'document':
      return '文档';
    case 'webBookmark':
      return '网页';
    case 'designFile':
      return '设计稿';
    case 'model3D':
      return '3D 模型';
  }
}

export function matchesSmartFolderRule(asset: AssetRecord, rule: SmartFolderRule): boolean {
  if (asset.isTrashed) return false;
  const checks: boolean[] = [];

  const cleanTags = rule.tags.map((t) => t.trim().toLowerCase()).filter(Boolean);
  if (cleanTags.length > 0) {
    const assetTags = new Set(asset.tags.map((t) => t.trim().toLowerCase()));
    checks.push(
      rule.matchMode === 'all'
        ? cleanTags.every((t) => assetTags.has(t))
        : cleanTags.some((t) => assetTags.has(t)),
    );
  }

  const q = rule.descriptionQuery.trim().toLowerCase();
  if (q) {
    const hay = [
      asset.title,
      asset.notes,
      asset.aiDescription ?? '',
      asset.ocrText ?? '',
      asset.richMetadata?.githubRepo?.fullName ?? '',
      asset.richMetadata?.githubRepo?.description ?? '',
      asset.richMetadata?.socialPost?.bodyText ?? '',
    ]
      .join('\n')
      .toLowerCase();
    const tokens = q.split(/\s+/).filter(Boolean);
    checks.push(tokens.every((tok) => hay.includes(tok)));
  }

  const cleanColors = rule.colorHexes.map((c) => c.trim().toLowerCase()).filter(Boolean);
  if (cleanColors.length > 0) {
    checks.push(
      asset.dominantColors.some((c) =>
        cleanColors.some((target) => hexDistanceApprox(c.hex, target) <= Math.max(24, rule.colorTolerance * 2.5)),
      ),
    );
  }

  if (rule.mediaKinds.length > 0) {
    checks.push(rule.mediaKinds.includes(asset.mediaKind));
  }
  if (rule.minRating > 0) {
    checks.push(asset.rating >= rule.minRating);
  }

  if (checks.length === 0) return false;
  return rule.matchMode === 'all' ? checks.every(Boolean) : checks.some(Boolean);
}

function hexDistanceApprox(hexA: string, hexB: string): number {
  const a = hexA.replace('#', '');
  const b = hexB.replace('#', '');
  if (a.length !== 6 || b.length !== 6) return 999;
  const dr = parseInt(a.slice(0, 2), 16) - parseInt(b.slice(0, 2), 16);
  const dg = parseInt(a.slice(2, 4), 16) - parseInt(b.slice(2, 4), 16);
  const db = parseInt(a.slice(4, 6), 16) - parseInt(b.slice(4, 6), 16);
  return Math.sqrt(dr * dr + dg * dg + db * db);
}
