import type { LabColor } from '../color/lab.js';

export type { LabColor } from '../color/lab.js';

/** Canonical hyphenated UUID string (normalized uppercase on Swift wire). */
export type UUID = string;

/** ISO-8601 UTC timestamp string (converted to Cocoa reference float seconds on Swift wire). */
export type ISODateString = string;

// MARK: - MediaKind

export type MediaKind =
  | 'image'
  | 'animatedImage'
  | 'video'
  | 'webBookmark'
  | 'document'
  | 'designFile'
  | 'audio'
  | 'model3D';

export const MEDIA_KINDS: readonly MediaKind[] = [
  'image',
  'animatedImage',
  'video',
  'webBookmark',
  'document',
  'designFile',
  'audio',
  'model3D',
] as const;

const MEDIA_KIND_LABELS: Record<MediaKind, string> = {
  image: '图片',
  animatedImage: '动图',
  video: '视频',
  webBookmark: '网页',
  document: '文档',
  designFile: '设计文件',
  audio: '音频',
  model3D: '3D 模型',
};

export function mediaKindLocalizedLabel(kind: MediaKind): string {
  return MEDIA_KIND_LABELS[kind];
}

const ANIMATED_IMAGE_EXTS = new Set(['gif', 'apng']);
const IMAGE_EXTS = new Set([
  'jpg',
  'jpeg',
  'png',
  'heic',
  'heif',
  'webp',
  'tiff',
  'tif',
  'bmp',
  'avif',
  'jxl',
]);
const VIDEO_EXTS = new Set(['mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi']);
const DOCUMENT_EXTS = new Set([
  'pdf',
  'md',
  'markdown',
  'txt',
  'rtf',
  'docx',
  'pptx',
  'key',
  'pages',
  'json',
  'yaml',
  'yml',
  'toml',
  'csv',
]);
const DESIGN_FILE_EXTS = new Set([
  'svg',
  'psd',
  'psb',
  'sketch',
  'fig',
  'ai',
  'eps',
  'xd',
  'afdesign',
  'afphoto',
]);
const AUDIO_EXTS = new Set([
  'mp3',
  'wav',
  'm4a',
  'aac',
  'flac',
  'ogg',
  'aiff',
  'aif',
  'opus',
  'caf',
  'alac',
  'wma',
  'm4b',
  'mid',
  'midi',
]);
const MODEL3D_EXTS = new Set([
  'usdz',
  'usda',
  'usdc',
  'obj',
  'stl',
  'scn',
  'dae',
  'gltf',
  'glb',
  'fbx',
  'ply',
  '3ds',
  'blend',
]);
const WEB_BOOKMARK_EXTS = new Set(['webloc', 'url']);

export function detectMediaKind(fileExtension: string, mimeType?: string | null): MediaKind {
  const lower = fileExtension.replace(/^\./, '').toLowerCase();
  if (ANIMATED_IMAGE_EXTS.has(lower)) return 'animatedImage';
  if (IMAGE_EXTS.has(lower)) return 'image';
  if (VIDEO_EXTS.has(lower)) return 'video';
  if (DOCUMENT_EXTS.has(lower)) return 'document';
  if (DESIGN_FILE_EXTS.has(lower)) return 'designFile';
  if (AUDIO_EXTS.has(lower)) return 'audio';
  if (MODEL3D_EXTS.has(lower)) return 'model3D';
  if (WEB_BOOKMARK_EXTS.has(lower)) return 'webBookmark';

  if (mimeType) {
    const mime = mimeType.toLowerCase();
    if (mime.startsWith('image/gif')) return 'animatedImage';
    if (mime.startsWith('image/svg')) return 'designFile';
    if (mime.startsWith('image/')) return 'image';
    if (mime.startsWith('video/')) return 'video';
    if (mime.startsWith('audio/')) return 'audio';
    if (mime.startsWith('model/')) return 'model3D';
    if (mime === 'application/pdf' || mime.startsWith('text/')) return 'document';
  }
  return 'document';
}

export const MediaKindUtils = {
  allCases: MEDIA_KINDS,
  detect: detectMediaKind,
  localizedLabel: mediaKindLocalizedLabel,
} as const;

// MARK: - Social & Rich Metadata

export type SocialPlatform = 'x' | 'threads' | 'bluesky';

export const SOCIAL_PLATFORMS: readonly SocialPlatform[] = ['x', 'threads', 'bluesky'] as const;

export function socialPlatformDisplayName(platform: SocialPlatform): string {
  switch (platform) {
    case 'x':
      return 'X';
    case 'threads':
      return 'Threads';
    case 'bluesky':
      return 'Bluesky';
  }
}

export function socialPlatformOpenActionLabel(platform: SocialPlatform): string {
  switch (platform) {
    case 'x':
      return '在 X 打开';
    case 'threads':
      return '在 Threads 打开';
    case 'bluesky':
      return '在 Bluesky 打开';
  }
}

export interface GitHubRepoMetadata {
  owner: string;
  repo: string;
  fullName: string;
  ownerAvatarURL?: string | null;
  description?: string | null;
  stars: number;
  forks: number;
  watchers?: number | null;
  language?: string | null;
  licenseName?: string | null;
  topics: string[];
  defaultBranch: string;
  homepageURL?: string | null;
  openGraphImageURL?: string | null;
  readmeMarkdown?: string | null;
  fetchedAt: ISODateString;
}

export type SocialMediaAttachmentKind = 'photo' | 'video' | 'gif';

export function socialMediaAttachmentLocalizedLabel(kind: SocialMediaAttachmentKind): string {
  switch (kind) {
    case 'photo':
      return '图片';
    case 'video':
      return '视频';
    case 'gif':
      return '动图';
  }
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
  mediaFetchFailed: boolean;
}

/**
 * Unified typed attachment list across both newly saved posts and legacy saved social posts.
 * Exact port of Swift `SocialPostMetadata.effectiveAttachments`.
 */
export function getEffectiveSocialAttachments(post: SocialPostMetadata): SocialMediaAttachment[] {
  if (post.attachments && post.attachments.length > 0) {
    return post.attachments;
  }
  const items: SocialMediaAttachment[] = [];
  const seen = new Set<string>();
  if (post.videoURL && post.videoURL.length > 0 && !seen.has(post.videoURL)) {
    seen.add(post.videoURL);
    items.push({
      id: `video:${post.videoURL}`,
      kind: 'video',
      url: post.videoURL,
      thumbnailURL: post.mediaThumbnailURLs[0] ?? null,
    });
  }
  for (let idx = 0; idx < post.mediaURLs.length; idx++) {
    const urlStr = post.mediaURLs[idx];
    if (seen.has(urlStr)) continue;
    seen.add(urlStr);
    const lower = urlStr.toLowerCase();
    const isVid =
      lower.includes('.mp4') ||
      lower.includes('.m3u8') ||
      lower.includes('/ext_tw_video/') ||
      lower.includes('/amplify_video/') ||
      lower.includes('video.twimg.com');
    const kind: SocialMediaAttachmentKind = isVid ? 'video' : 'photo';
    const thumb = idx < post.mediaThumbnailURLs.length ? post.mediaThumbnailURLs[idx] : null;
    items.push({
      id: `${kind}:${urlStr}`,
      kind,
      url: urlStr,
      thumbnailURL: thumb,
    });
  }
  return items;
}

export interface AssetRichMetadata {
  githubRepo?: GitHubRepoMetadata | null;
  socialPost?: SocialPostMetadata | null;
  textExcerpt?: string | null;
  isMarkdown: boolean;
  model3DFormat?: string | null;
}

// MARK: - AspectShape

export type AspectShape = 'landscape' | 'portrait' | 'square' | 'ultrawide';

export const ASPECT_SHAPES: readonly AspectShape[] = [
  'landscape',
  'portrait',
  'square',
  'ultrawide',
] as const;

export function aspectShapeLocalizedLabel(shape: AspectShape): string {
  switch (shape) {
    case 'landscape':
      return '横图';
    case 'portrait':
      return '竖图';
    case 'square':
      return '方图';
    case 'ultrawide':
      return '超宽';
  }
}

export function classifyAspectShape(width: number, height: number): AspectShape {
  if (width <= 0 || height <= 0) return 'square';
  const ratio = width / height;
  if (ratio >= 2.0) return 'ultrawide';
  if (ratio >= 1.15) return 'landscape';
  if (ratio <= 0.87) return 'portrait';
  return 'square';
}

// MARK: - AssetRecord

export interface AssetRecord {
  id: UUID;
  title: string;
  fileName: string;
  folderID?: UUID | null;
  driveFileID?: string | null;
  contentHash: string;
  mediaKind: MediaKind;
  mimeType: string;
  fileSizeBytes: number;
  pixelWidth: number;
  pixelHeight: number;
  durationSeconds?: number | null;
  waveformPeaks: number[];
  sourceURL?: string | null;
  sourceDomain?: string | null;
  notes: string;
  tags: string[];
  suggestedTags: string[];
  aiDescription?: string | null;
  ocrText?: string | null;
  dominantColors: LabColor[];
  rating: number;
  pinnedOffline: boolean;
  isLocalOriginalCached: boolean;
  isTrashed: boolean;
  createdAt: ISODateString;
  updatedAt: ISODateString;
  updatedHLC: number;
  lastOpenedAt?: ISODateString | null;
  richMetadata?: AssetRichMetadata | null;
}

const PLAIN_TEXT_EXTS = new Set([
  'txt',
  'md',
  'markdown',
  'json',
  'yaml',
  'yml',
  'toml',
  'csv',
  'rtf',
]);

function filePathExtension(fileName: string): string {
  const dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot === fileName.length - 1) return '';
  return fileName.slice(dot + 1).toLowerCase();
}

export function getAssetAspectRatio(asset: Pick<AssetRecord, 'pixelWidth' | 'pixelHeight'>): number {
  if (asset.pixelWidth <= 0 || asset.pixelHeight <= 0) return 1.0;
  return asset.pixelWidth / asset.pixelHeight;
}

export function getAssetAspectShape(asset: Pick<AssetRecord, 'pixelWidth' | 'pixelHeight'>): AspectShape {
  return classifyAspectShape(asset.pixelWidth, asset.pixelHeight);
}

export function isAssetInInbox(asset: Pick<AssetRecord, 'folderID' | 'isTrashed'>): boolean {
  return !asset.folderID && !asset.isTrashed;
}

export function getAssetRecentActivityDate(
  asset: Pick<AssetRecord, 'createdAt' | 'lastOpenedAt'>,
): ISODateString {
  if (!asset.lastOpenedAt) return asset.createdAt;
  return Date.parse(asset.lastOpenedAt) > Date.parse(asset.createdAt)
    ? asset.lastOpenedAt
    : asset.createdAt;
}

export function isGitHubRepoAsset(asset: Pick<AssetRecord, 'richMetadata'>): boolean {
  return Boolean(asset.richMetadata?.githubRepo);
}

export function isSocialPostAsset(asset: Pick<AssetRecord, 'richMetadata'>): boolean {
  return Boolean(asset.richMetadata?.socialPost);
}

export function getAssetDisplayTypeLabel(
  asset: Pick<AssetRecord, 'mediaKind' | 'richMetadata'>,
): string {
  if (asset.richMetadata?.socialPost) {
    return `${socialPlatformDisplayName(asset.richMetadata.socialPost.platform)} 推文`;
  }
  if (asset.richMetadata?.githubRepo) {
    return 'GitHub 仓库';
  }
  return mediaKindLocalizedLabel(asset.mediaKind);
}

export function isMarkdownDocumentAsset(
  asset: Pick<AssetRecord, 'mediaKind' | 'fileName' | 'richMetadata'>,
): boolean {
  if (asset.richMetadata?.isMarkdown) return true;
  const ext = filePathExtension(asset.fileName);
  return asset.mediaKind === 'document' && (ext === 'md' || ext === 'markdown');
}

export function isPlainTextDocumentAsset(
  asset: Pick<AssetRecord, 'mediaKind' | 'fileName'>,
): boolean {
  const ext = filePathExtension(asset.fileName);
  return asset.mediaKind === 'document' && PLAIN_TEXT_EXTS.has(ext);
}

export function createDefaultAssetRecord(
  overrides: Partial<AssetRecord> & Pick<AssetRecord, 'id' | 'title' | 'fileName'>,
): AssetRecord {
  const now = new Date().toISOString();
  return {
    folderID: null,
    driveFileID: null,
    contentHash: '',
    mediaKind: 'image',
    mimeType: 'image/jpeg',
    fileSizeBytes: 0,
    pixelWidth: 1200,
    pixelHeight: 900,
    durationSeconds: null,
    waveformPeaks: [],
    sourceURL: null,
    sourceDomain: null,
    notes: '',
    tags: [],
    suggestedTags: [],
    aiDescription: null,
    ocrText: null,
    dominantColors: [],
    rating: 0,
    pinnedOffline: false,
    isLocalOriginalCached: false,
    isTrashed: false,
    createdAt: now,
    updatedAt: now,
    updatedHLC: 0,
    lastOpenedAt: null,
    richMetadata: null,
    ...overrides,
  };
}

// MARK: - Folders, Tags & Smart Folders

export interface FolderRecord {
  id: UUID;
  name: string;
  parentID?: UUID | null;
  driveFolderID?: string | null;
  colorHex?: string | null;
  customSymbol?: string | null;
  sortOrder: number;
  assetCount: number;
  createdAt: ISODateString;
  updatedAt: ISODateString;
}

export interface TagCount {
  name: string;
  count: number;
}

export type SmartFolderMatchMode = 'all' | 'any';

export function smartFolderMatchModeLabel(mode: SmartFolderMatchMode): string {
  return mode === 'all' ? '满足全部条件' : '满足任一条件';
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

export function createDefaultSmartFolderRule(
  overrides: Partial<SmartFolderRule> = {},
): SmartFolderRule {
  return {
    matchMode: 'all',
    tags: [],
    descriptionQuery: '',
    colorHexes: [],
    colorTolerance: 24.0,
    mediaKinds: [],
    minRating: 0,
    ...overrides,
  };
}

export interface SmartFolderRecord {
  id: UUID;
  name: string;
  colorHex?: string | null;
  rule: SmartFolderRule;
  sortOrder: number;
  createdAt: ISODateString;
  updatedAt: ISODateString;
}

// MARK: - Sorting, Gallery Layout, Navigation & Filtering

export type SortOrder =
  | 'newest'
  | 'oldest'
  | 'nameAsc'
  | 'ratingDesc'
  | 'fileSizeDesc'
  | 'relevance';

export const SORT_ORDERS: readonly SortOrder[] = [
  'newest',
  'oldest',
  'nameAsc',
  'ratingDesc',
  'fileSizeDesc',
  'relevance',
] as const;

export function sortOrderLocalizedLabel(order: SortOrder): string {
  switch (order) {
    case 'newest':
      return '最新添加';
    case 'oldest':
      return '最早添加';
    case 'nameAsc':
      return '名称 A→Z';
    case 'ratingDesc':
      return '评分最高';
    case 'fileSizeDesc':
      return '文件最大';
    case 'relevance':
      return '最相关';
  }
}

export type GalleryLayoutMode = 'verticalMasonry' | 'horizontalJustified' | 'galleryFilmstrip';

export const GALLERY_LAYOUT_MODES: readonly GalleryLayoutMode[] = [
  'verticalMasonry',
  'horizontalJustified',
  'galleryFilmstrip',
] as const;

export function galleryLayoutModeLocalizedLabel(mode: GalleryLayoutMode): string {
  switch (mode) {
    case 'verticalMasonry':
      return '纵向瀑布流';
    case 'horizontalJustified':
      return '横向瀑布流';
    case 'galleryFilmstrip':
      return '画廊视图';
  }
}

export type SidebarDestination =
  | { type: 'allItems' }
  | { type: 'inbox' }
  | { type: 'moodboardsHome' }
  | { type: 'moodboard'; id: UUID }
  | { type: 'untagged' }
  | { type: 'recent' }
  | { type: 'trash' }
  | { type: 'folder'; id: UUID }
  | { type: 'smartFolder'; id: UUID }
  | { type: 'tag'; name: string };

export interface FilterCriteria {
  searchQuery: string;
  kinds: MediaKind[];
  selectedColorHex?: string | null;
  colorTolerance: number;
  shape?: AspectShape | null;
  minRating: number;
  tags: string[];
  folderID?: UUID | null;
  includeSubfolders: boolean;
  onlyInbox: boolean;
  onlyUntagged: boolean;
  onlyRecentDays?: number | null;
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
    colorTolerance: 28.0,
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

export function hasActiveVisualFilters(criteria: FilterCriteria): boolean {
  return (
    criteria.kinds.length > 0 ||
    Boolean(criteria.selectedColorHex) ||
    Boolean(criteria.shape) ||
    criteria.minRating > 0 ||
    criteria.tags.length > 0 ||
    criteria.onlyPinnedOffline
  );
}

export function clearVisualFilters(criteria: FilterCriteria): FilterCriteria {
  return {
    ...criteria,
    kinds: [],
    selectedColorHex: null,
    shape: null,
    minRating: 0,
    tags: [],
    onlyPinnedOffline: false,
  };
}

// MARK: - Batch Mutations, Quick Jump & Suggestions

export type FolderAssignment =
  | { type: 'unchanged' }
  | { type: 'inbox' }
  | { type: 'folder'; folderID: UUID };

export interface AssetBatchPatch {
  assetIDs: UUID[];
  title?: string | null;
  notes?: string | null;
  rating?: number | null;
  addTags: string[];
  removeTags: string[];
  acceptSuggestedTags: boolean;
  dismissSuggestedTags: string[];
  folderAssignment: FolderAssignment;
  pinnedOffline?: boolean | null;
  isTrashed?: boolean | null;
}

export function createDefaultAssetBatchPatch(
  assetIDs: UUID[],
  overrides: Partial<Omit<AssetBatchPatch, 'assetIDs'>> = {},
): AssetBatchPatch {
  return {
    assetIDs,
    title: null,
    notes: null,
    rating: null,
    addTags: [],
    removeTags: [],
    acceptSuggestedTags: false,
    dismissSuggestedTags: [],
    folderAssignment: { type: 'unchanged' },
    pinnedOffline: null,
    isTrashed: null,
    ...overrides,
  };
}

export type QuickJumpKind = 'folder' | 'moodboard' | 'tag' | 'asset';

export interface QuickJumpMatch {
  id: string;
  kind: QuickJumpKind;
  title: string;
  subtitle: string;
  targetUUID?: UUID | null;
  tagName?: string | null;
  score: number;
}

export interface ScoredAsset {
  asset: AssetRecord;
  score: number;
  matchReasons: string[];
}

export interface FolderSuggestion {
  folderID: UUID;
  folderName: string;
  confidence: number;
  reason: string;
}
