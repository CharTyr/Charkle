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
  | 'galleryFilmstrip'
  | 'ringGallery';

export type SocialPlatform = 'x' | 'threads' | 'bluesky' | 'xiaohongshu';
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
  ownerAvatarURL?: string | null;
  description?: string | null;
  language?: string | null;
  stars: number;
  forks: number;
  watchers?: number | null;
  openIssues?: number;
  licenseName?: string | null;
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

/**
 * Formats a clean social handle subtitle, omitting empty handles and internal
 * 24-character hex Xiaohongshu userIds, generic `'xiaohongshu'`, or duplicate nicknames.
 */
export function formatSocialDisplayHandle(
  post: Pick<SocialPostMetadata, 'platform' | 'authorName' | 'authorHandle'>,
): string | null {
  const clean = (post.authorHandle ?? '').trim().replace(/^@+/, '').trim();
  if (!clean) return null;
  if (post.platform === 'xiaohongshu') {
    if (
      /^[0-9a-f]{24}$/i.test(clean) ||
      clean.toLowerCase() === 'xiaohongshu' ||
      clean === (post.authorName ?? '').trim()
    ) {
      return null;
    }
  }
  return `@${clean}`;
}

/**
 * Routes Xiaohongshu CDN media/avatar URLs through the local Tauri media proxy
 * so Rust injects `Referer: https://www.xiaohongshu.com/` and prevents HTTP 403.
 */
export function resolveSocialMediaUrl(
  rawUrl: string | null | undefined,
  isTauri: boolean,
): string | undefined {
  const trimmed = rawUrl?.trim();
  if (!trimmed) return undefined;
  if (!isTauri) return trimmed;
  try {
    const host = new URL(trimmed).hostname.toLowerCase();
    if (
      host === 'xhscdn.com' ||
      host.endsWith('.xhscdn.com') ||
      host === 'xiaohongshu.com' ||
      host.endsWith('.xiaohongshu.com')
    ) {
      return `http://charkle-media.localhost/proxy-xhs?url=${encodeURIComponent(trimmed)}`;
    }
  } catch {
    // Preserve raw URL if not parseable as absolute URL
  }
  return trimmed;
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
  altitudeMeters?: number | null;
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

export interface BoardPoint {
  x: number;
  y: number;
}

export interface BoardRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface NormalizedCropRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type EditorialStyle = 'balanced' | 'magazine' | 'compact';

export interface AutoLayoutConfig {
  columns: number;
  spacing: number;
  style: EditorialStyle;
  showPaletteStrip: boolean;
}

export type BoardLayoutMode =
  | { autoEditorial: { _0: AutoLayoutConfig } }
  | { freeform: Record<string, never> };

export function isAutoEditorialMode(
  mode: BoardLayoutMode,
): mode is { autoEditorial: { _0: AutoLayoutConfig } } {
  return 'autoEditorial' in mode;
}

export type BoardNodeKind =
  | {
      assetRef: {
        assetID: string;
        crop?: NormalizedCropRect | null;
        weight: number;
        autoplayLoop: boolean;
      };
    }
  | {
      note: {
        title?: string | null;
        text: string;
        style: NoteStyle;
        fontSize: number;
      };
    }
  | {
      groupFrame: {
        title: string;
        tint: GroupTint;
      };
    }
  | {
      paletteStrip: {
        colors: LabColor[];
        autoSyncWithBoard: boolean;
      };
    };

export interface BoardNode {
  id: string;
  kind: BoardNodeKind;
  frame: BoardRect;
  zIndex: number;
  rotationDegrees: number;
  flipHorizontal: boolean;
  flipVertical: boolean;
  isLocked: boolean;
  editorialOrder: number;
  updatedAt: WireDate;
}

export type ConnectorAnchor = 'auto' | 'top' | 'bottom' | 'leading' | 'trailing';
export type ConnectorStyle = 'curved' | 'elbow' | 'straight';

export interface BoardConnector {
  id: string;
  fromNodeID: string;
  fromAnchor: ConnectorAnchor;
  fromNormalizedPoint?: BoardPoint | null;
  toNodeID: string;
  toAnchor: ConnectorAnchor;
  toNormalizedPoint?: BoardPoint | null;
  label?: string | null;
  colorHex: string;
  style: ConnectorStyle;
  dashed: boolean;
  updatedAt: WireDate;
}

export interface InkStrokePoint {
  x: number;
  y: number;
  pressure: number;
}

export interface InkStroke {
  id: string;
  points: InkStrokePoint[];
  colorHex: string;
  lineWidth: number;
  opacity: number;
  zIndex: number;
  createdAt: WireDate;
}

export interface MoodboardSummary {
  id: string;
  title: string;
  subtitle: string;
  mode?: BoardLayoutMode;
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
  mode: BoardLayoutMode;
  nodes: BoardNode[];
  connectors: BoardConnector[];
  inkStrokes: InkStroke[];
  extractedPalette: LabColor[];
  candidateAssetIDs: string[];
  pinnedOffline: boolean;
  viewportCenter: BoardPoint;
  viewportZoom: number;
  createdAt: WireDate;
  updatedAt: WireDate;
  updatedHLC: number;
}

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
  id: string;
  phase: MoodboardAgentPhase;
  title: string;
  detail: string;
  status: MoodboardAgentStepStatus;
  timestamp: WireDate;
}

export interface MoodboardSectionDraft {
  id: string;
  title: string;
  tint: GroupTint;
  rationale: string;
  assetIDs: string[];
  heroAssetIDs: string[];
}

export interface MoodboardCurationRequest {
  prompt: string;
  seedAssetIDs: string[];
  scopeFolderIDs: string[];
  requiredTags: string[];
  targetPalette: LabColor[];
  colorTolerance: number;
  preferredCount: number;
  candidateCount: number;
  layoutStyle: EditorialStyle;
  useFreeformLayout: boolean;
  includeCuratorNotes: boolean;
  excludedAssetIDs: string[];
  lockedAssetIDs: string[];
  existingBoard?: MoodboardDocument | null;
  refinementInstruction?: string | null;
  autoFocusDetailCrop: boolean;
}

export interface MoodboardProposal {
  draftDocument: MoodboardDocument;
  primaryMatches: ScoredAsset[];
  candidatePool: ScoredAsset[];
  extractedPalette: LabColor[];
  usedCloudAi: boolean;
  curatedSummary: string;
  agentTrace: MoodboardAgentStep[];
  sections: MoodboardSectionDraft[];
  rejectedSummary?: string | null;
  cachedVisualInsightsCount: number;
}

export type BoardImageFormat = 'png' | 'jpeg';

export interface MoodboardExportOptions {
  scale: number;
  format: BoardImageFormat;
  includeAnnotations: boolean;
  includePaletteStrip: boolean;
  darkAppearance: boolean;
  containerWidth: number;
}

export interface FigmaBridgeExportReport {
  objectCount: number;
  imageCount: number;
  noteCount: number;
  groupCount: number;
  paletteCount: number;
  connectorCount: number;
  strokeCount: number;
  reviewCount: number;
  bundlePath: string;
}

export interface EditorialLayoutResult {
  frames: Record<string, BoardRect>;
  orderedNodeIds: string[];
  contentSize: { width: number; height: number };
  columnWidth: number;
  columnCount: number;
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

export type DragOutOutcome = 'copied' | 'moved' | 'linked' | 'cancelled';

export type ShelfTargetMode = 'inbox' | 'folder' | 'activeMoodboard';

export interface HotkeyConfig {
  enabled: boolean;
  captureArea: string;
  toggleShelf: string;
  collectClipboard: string;
}

export interface MonitorCaptureInfo {
  index: number;
  left: number;
  top: number;
  width: number;
  height: number;
  dpiX: number;
  dpiY: number;
  scaleFactor: number;
  isPrimary: boolean;
}

export interface VirtualDesktopBounds {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface CaptureSessionInfo {
  token: string;
  bounds: VirtualDesktopBounds;
  monitors: MonitorCaptureInfo[];
  width: number;
  height: number;
  targetFolderId?: string | null;
  targetBoardId?: string | null;
}

export interface ClipboardPreview {
  kind: 'image' | 'files' | 'url' | 'color' | 'text' | string;
  label: string;
  url?: string | null;
  hex?: string | null;
  fileCount: number;
  isSocialOrGithubUrl: boolean;
}

export interface OcrDiagnostics {
  availableLanguages: string[];
  selectedLanguage?: string | null;
  hasChinese: boolean;
  hasEnglish: boolean;
  diagnosticMessage?: string | null;
}

export interface DesktopIntegrationStatus {
  hotkeys: HotkeyConfig;
  autostartEnabled: boolean;
  trayActive: boolean;
  deepLinkScheme: string;
  ocr: OcrDiagnostics;
  gdirectPath?: string | null;
  shelfVisible: boolean;
  shelfPinned: boolean;
}

export type DeepLinkPayload =
  | { action: 'openAsset'; id: string }
  | { action: 'openFolder'; id: string }
  | { action: 'openBoard'; id: string }
  | { action: 'captureArea' }
  | { action: 'toggleShelf' };

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

// =========================================================================
// M5 Hybrid Cloud AI, Usage Telemetry, TypeSafe Jev, External Agent & Settings
// =========================================================================

export type SettingsTabId =
  | 'general'
  | 'library'
  | 'sync'
  | 'dropShelf'
  | 'captureShortcuts'
  | 'ai'
  | 'externalAgents'
  | 'extensions'
  | 'advancedAbout';

export type CloudAIProviderKind =
  | 'disabled'
  | 'chatGPTSubscription'
  | 'gemini'
  | 'openAICompatible';

export type CustomAIEndpointFormat =
  | 'openAIChatCompletions'
  | 'anthropicMessages'
  | 'openAIResponses';

export interface AIProviderConfig {
  provider: CloudAIProviderKind;
  customEndpointFormat: CustomAIEndpointFormat;
  baseURL: string;
  chatModel: string;
  embeddingModel: string;
  autoAnalyzeOnImport: boolean;
  sendThumbnailsToCloud: boolean;
}

export interface ChatGPTAccountSession {
  status: 'disconnected' | 'connected' | 'reauthRequired';
  sharingEnabled: boolean;
  email?: string | null;
  name?: string | null;
  subject?: string | null;
  lastUpdatedAt?: WireDate | null;
}

export type CloudAIUsageCategory = 'standard' | 'jev';

export interface CloudAIUsageBucket {
  dayKey: string;
  todayRequests: number;
  todayInputTokens: number;
  todayOutputTokens: number;
  todayTotalTokens: number;
  totalRequests: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  totalTokens: number;
  lastProviderLabel?: string | null;
  lastModel?: string | null;
  lastUsedAt?: WireDate | null;
  lastCallTokens: number;
}

export interface CloudAIUsageSummary {
  dayKey: string;
  todayRequests: number;
  todayInputTokens: number;
  todayOutputTokens: number;
  todayTotalTokens: number;
  totalRequests: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  totalTokens: number;
  lastProviderLabel?: string | null;
  lastModel?: string | null;
  lastUsedAt?: WireDate | null;
  lastCallTokens: number;
  standard: CloudAIUsageBucket;
  jev: CloudAIUsageBucket;
}

export interface AIProviderStateDto {
  config: AIProviderConfig;
  hasApiKey: boolean;
  chatgptSession: ChatGPTAccountSession;
  usage: CloudAIUsageSummary;
}

export interface AIConnectionTestResult {
  ok: boolean;
  providerLabel: string;
  model: string;
  message: string;
  latencyMs: number;
}

export interface TypeSafeExperimentalConfig {
  enabled: boolean;
  baseURL: string;
  model: string;
  minConfidence: number;
  lowConfidencePadding: number;
  minPresenceProbability: number;
  enableMoodboardFocusCrop: boolean;
  enableAutoCleanCrop: boolean;
  enableSubjectPalette: boolean;
  enablePinpointAnnotations: boolean;
  enableSemanticSearch: boolean;
  enableInboxSmartTriage: boolean;
  enableCuratorVisualRerank: boolean;
}

export interface TypeSafeModelInfo {
  name: string;
  description: string;
  release_date: string;
}

export interface TypeSafeStateDto {
  config: TypeSafeExperimentalConfig;
  hasApiKey: boolean;
}

export interface TypeSafeTestResultDto {
  ok: boolean;
  message: string;
  models: TypeSafeModelInfo[];
}

export interface InboxTriageRecommendation {
  assetID: string;
  assetTitle: string;
  recommendedFolderID?: string | null;
  recommendedFolderName?: string | null;
  confidence: number;
  fitProbability: number;
  reason: string;
  source: 'typeSafeJev' | 'appleVisionSaliency';
}

export type ExternalAgentAccessLevel = 'readOnly' | 'readWriteOrganize';

export interface ExternalAgentConfig {
  enabled?: boolean;
  mcpEnabled: boolean;
  cliEnabled: boolean;
  accessLevel: ExternalAgentAccessLevel;
}

export interface ExternalAgentStateDto {
  config: ExternalAgentConfig;
  cliBinaryPath: string;
  libraryDir: string;
  mcpConfigJson: string;
  readToolCount: number;
  writeToolCount: number;
  resourceCount: number;
}

export interface StorageMigrationReport {
  sourceMode: DriveTransportMode;
  targetMode: DriveTransportMode;
  targetLocation: string;
  downloadedOriginals: number;
  migratedAssets: number;
  migratedFolders: number;
  migratedBoards: number;
  durationSeconds: number;
}

export interface GDirectEnvironmentSnapshot {
  cliPath?: string | null;
  cliVersion?: string | null;
  appVersion?: string | null;
  hasVersionMismatch: boolean;
  rclonePath?: string | null;
  accounts: string[];
  defaultAccount?: string | null;
  endpoints: Array<{ ip: string; latencyMs: number; healthy: boolean }>;
  mountPath: string;
  isMountActive: boolean;
  bypassTunEnabled: boolean;
}

export interface SystemDiagnosticsDto {
  appVersion: string;
  schemaVersion: number;
  dataDir: string;
  databasePath: string;
  gdirect: GDirectEnvironmentSnapshot;
  ocr: OcrDiagnostics;
}

export interface SyncAuthStateDto {
  hasGoogleOAuthClient: boolean;
  hasWebdavPassword: boolean;
}

export interface WebdavTestResultDto {
  ok: boolean;
  message: string;
}

export interface ExternalAgentSelfCheckDto {
  ok: boolean;
  summary: string;
}

export interface RebuildIndexResultDto {
  processed: number;
  total: number;
}

export interface ShelfSettings {
  enabled: boolean;
  hoverTriggerEnabled: boolean;
  defaultTargetMode: ShelfTargetMode;
  defaultFolderId?: string | null;
  minimalMode?: boolean;
}

export interface ExtensionBridgeStateDto {
  enabled: boolean;
  running: boolean;
  port: number;
  baseUrl: string;
  allowLocalAutoPair: boolean;
  accessToken: string;
  lastError?: string | null;
  bundledExtensionDir?: string | null;
  bundledExtensionManifestPath?: string | null;
}
