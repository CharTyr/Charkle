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

export function getPhotoExifCameraDisplayName(exif: PhotoExifMetadata): string | null {
  const make = exif.cameraMake?.trim() ?? '';
  const model = exif.cameraModel?.trim() ?? '';
  if (!make && !model) return null;
  if (!model) return make;
  if (!make) return model;
  if (model.toLowerCase().startsWith(make.toLowerCase())) {
    return model;
  }
  return `${make} ${model}`;
}

export function formatPhotoExifAperture(exif: PhotoExifMetadata): string | null {
  if (exif.fNumber == null || !Number.isFinite(exif.fNumber) || exif.fNumber <= 0) {
    return null;
  }
  const rounded = Math.round(exif.fNumber * 10) / 10;
  if (Math.abs(rounded - Math.round(rounded)) < 0.01) {
    return `f/${Math.round(rounded)}`;
  }
  return `f/${rounded.toFixed(1)}`;
}

export function formatPhotoExifFocalLength(exif: PhotoExifMetadata): string | null {
  if (exif.focalLengthMM == null || !Number.isFinite(exif.focalLengthMM) || exif.focalLengthMM <= 0) {
    return null;
  }
  const base =
    Math.abs(exif.focalLengthMM - Math.round(exif.focalLengthMM)) < 0.05
      ? `${Math.round(exif.focalLengthMM)}mm`
      : `${exif.focalLengthMM.toFixed(1)}mm`;
  if (
    exif.focalLength35mm != null &&
    Number.isFinite(exif.focalLength35mm) &&
    exif.focalLength35mm > 0 &&
    Math.abs(exif.focalLength35mm - exif.focalLengthMM) >= 1.5
  ) {
    return `${base}（等效 ${Math.round(exif.focalLength35mm)}mm）`;
  }
  return base;
}

export function getPhotoExifExposureSummary(exif: PhotoExifMetadata): string | null {
  const parts: string[] = [];
  if (exif.focalLengthMM != null && Number.isFinite(exif.focalLengthMM) && exif.focalLengthMM > 0) {
    if (Math.abs(exif.focalLengthMM - Math.round(exif.focalLengthMM)) < 0.05) {
      parts.push(`${Math.round(exif.focalLengthMM)}mm`);
    } else {
      parts.push(`${exif.focalLengthMM.toFixed(1)}mm`);
    }
  }
  const aperture = formatPhotoExifAperture(exif);
  if (aperture) parts.push(aperture);
  if (exif.exposureTime && exif.exposureTime.trim().length > 0) {
    parts.push(exif.exposureTime.trim());
  }
  if (exif.iso != null && Number.isFinite(exif.iso) && exif.iso > 0) {
    parts.push(`ISO ${Math.round(exif.iso)}`);
  }
  return parts.length > 0 ? parts.join(' · ') : null;
}

export function hasMeaningfulCameraExif(exif?: PhotoExifMetadata | null): boolean {
  if (!exif) return false;
  return Boolean(
    getPhotoExifCameraDisplayName(exif) !== null ||
      (exif.lensModel && exif.lensModel.trim().length > 0) ||
      (exif.capturedAt && exif.capturedAt.trim().length > 0) ||
      (exif.exposureTime && exif.exposureTime.trim().length > 0) ||
      exif.fNumber != null ||
      exif.iso != null ||
      exif.focalLengthMM != null ||
      exif.latitude != null ||
      (exif.software && exif.software.trim().length > 0) ||
      (exif.artist && exif.artist.trim().length > 0) ||
      (exif.copyright && exif.copyright.trim().length > 0),
  );
}

export function isPhotoExifEmpty(exif?: PhotoExifMetadata | null): boolean {
  if (!exif) return true;
  return (
    !hasMeaningfulCameraExif(exif) &&
    !(exif.colorProfile && exif.colorProfile.trim().length > 0) &&
    exif.bitDepth == null &&
    exif.dpiWidth == null
  );
}

export function isAIGenerationEmpty(ai?: AIGenerationMetadata | null): boolean {
  if (!ai) return true;
  const hasPrompt = Boolean(ai.prompt && ai.prompt.trim().length > 0);
  const hasNeg = Boolean(ai.negativePrompt && ai.negativePrompt.trim().length > 0);
  const hasRaw = Boolean(ai.rawParameters && ai.rawParameters.trim().length > 0);
  return (
    !hasPrompt &&
    !hasNeg &&
    !(ai.modelName && ai.modelName.trim().length > 0) &&
    !(ai.sampler && ai.sampler.trim().length > 0) &&
    ai.steps == null &&
    !(ai.seed && ai.seed.trim().length > 0) &&
    !hasRaw
  );
}

export interface AssetRichMetadata {
  githubRepo?: GitHubRepoMetadata | null;
  socialPost?: SocialPostMetadata | null;
  photoExif?: PhotoExifMetadata | null;
  aiGeneration?: AIGenerationMetadata | null;
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

export interface FolderHierarchyNode {
  id: UUID;
  folder: FolderRecord;
  depth: number;
  children: FolderHierarchyNode[];
}

export function sortedFolderSiblings(items: readonly FolderRecord[]): FolderRecord[] {
  return [...items].sort((lhs, rhs) => {
    if (lhs.sortOrder !== rhs.sortOrder) return lhs.sortOrder - rhs.sortOrder;
    const nameCmp = lhs.name.localeCompare(rhs.name, undefined, { sensitivity: 'base' });
    if (nameCmp !== 0) return nameCmp;
    return lhs.id < rhs.id ? -1 : lhs.id > rhs.id ? 1 : 0;
  });
}

export function buildFolderTree(folders: readonly FolderRecord[]): FolderHierarchyNode[] {
  const byParent = new Map<UUID | null, FolderRecord[]>();
  const knownIDs = new Set<UUID>();
  for (const folder of folders) {
    knownIDs.add(folder.id);
    const parentKey = folder.parentID ?? null;
    const list = byParent.get(parentKey);
    if (list) list.push(folder);
    else byParent.set(parentKey, [folder]);
  }

  const visited = new Set<UUID>();
  const makeNodes = (records: readonly FolderRecord[], depth: number): FolderHierarchyNode[] => {
    const nodes: FolderHierarchyNode[] = [];
    for (const folder of sortedFolderSiblings(records)) {
      if (visited.has(folder.id)) continue;
      visited.add(folder.id);
      const children = makeNodes(byParent.get(folder.id) ?? [], depth + 1);
      nodes.push({ id: folder.id, folder, depth, children });
    }
    return nodes;
  };

  const roots = folders.filter((folder) => !folder.parentID || !knownIDs.has(folder.parentID));
  const forest = makeNodes(roots, 0);

  const remaining = folders.filter((folder) => !visited.has(folder.id));
  if (remaining.length > 0) {
    forest.push(...makeNodes(remaining, 0));
  }
  return forest;
}

export function flattenFolderTree(folders: readonly FolderRecord[]): FolderHierarchyNode[] {
  const result: FolderHierarchyNode[] = [];
  const walk = (nodes: readonly FolderHierarchyNode[]): void => {
    for (const node of nodes) {
      result.push(node);
      if (node.children.length > 0) {
        walk(node.children);
      }
    }
  };
  walk(buildFolderTree(folders));
  return result;
}

export function folderNodeContains(node: FolderHierarchyNode, folderID?: UUID | null): boolean {
  if (!folderID) return false;
  if (node.folder.id === folderID) return true;
  return node.children.some((child) => folderNodeContains(child, folderID));
}

export function buildFolderPathsMap(folders: readonly FolderRecord[]): Record<UUID, string> {
  const byID = new Map<UUID, FolderRecord>();
  for (const folder of folders) {
    byID.set(folder.id, folder);
  }
  const paths: Record<UUID, string> = {};
  for (const folder of folders) {
    const segments: string[] = [];
    const seen = new Set<UUID>();
    let current: FolderRecord | undefined = folder;
    while (current && !seen.has(current.id)) {
      seen.add(current.id);
      segments.push(current.name);
      current = current.parentID ? byID.get(current.parentID) : undefined;
    }
    paths[folder.id] = segments.reverse().join('/');
  }
  return paths;
}

export type InspectorInfoSection =
  | 'previewIdentity'
  | 'quickActions'
  | 'colorsAndTags'
  | 'notesAndOCR'
  | 'aiGeneration'
  | 'photoExif'
  | 'mediaSpecs'
  | 'githubRepo'
  | 'socialMediaExtract';

export const DEFAULT_INSPECTOR_SECTION_ORDER: readonly InspectorInfoSection[] = [
  'previewIdentity',
  'quickActions',
  'colorsAndTags',
  'notesAndOCR',
  'aiGeneration',
  'photoExif',
  'mediaSpecs',
  'githubRepo',
  'socialMediaExtract',
] as const;

const INSPECTOR_SECTION_SET: ReadonlySet<string> = new Set(DEFAULT_INSPECTOR_SECTION_ORDER);

const INSPECTOR_SECTION_TITLES: Record<InspectorInfoSection, string> = {
  previewIdentity: '素材预览',
  quickActions: '快捷操作',
  colorsAndTags: '色板与标签',
  notesAndOCR: '备注与识别文本',
  aiGeneration: 'AI 生图信息',
  photoExif: '拍摄参数 (EXIF)',
  mediaSpecs: '媒体信息',
  githubRepo: 'GitHub 仓库信息',
  socialMediaExtract: '推文媒体提取',
};

export function inspectorInfoSectionTitle(section: InspectorInfoSection): string {
  return INSPECTOR_SECTION_TITLES[section];
}

export function normalizeInspectorSectionOrder(rawValues: readonly string[]): InspectorInfoSection[] {
  const result: InspectorInfoSection[] = [];
  const seen = new Set<InspectorInfoSection>();
  for (const raw of rawValues) {
    if (INSPECTOR_SECTION_SET.has(raw)) {
      const section = raw as InspectorInfoSection;
      if (!seen.has(section)) {
        seen.add(section);
        result.push(section);
      }
    }
  }
  for (const fallback of DEFAULT_INSPECTOR_SECTION_ORDER) {
    if (!seen.has(fallback)) {
      seen.add(fallback);
      result.push(fallback);
    }
  }
  return result;
}

export function moveInspectorSection(
  dragged: InspectorInfoSection,
  target: InspectorInfoSection,
  order: readonly InspectorInfoSection[],
): InspectorInfoSection[] {
  if (dragged === target) return [...order];
  const fromIdx = order.indexOf(dragged);
  const toIdx = order.indexOf(target);
  if (fromIdx < 0 || toIdx < 0) return [...order];
  const next = [...order];
  const [item] = next.splice(fromIdx, 1);
  next.splice(toIdx, 0, item);
  return next;
}

export function moveInspectorSectionToTop(
  section: InspectorInfoSection,
  order: readonly InspectorInfoSection[],
): InspectorInfoSection[] {
  const idx = order.indexOf(section);
  if (idx <= 0) return [...order];
  const next = [...order];
  const [item] = next.splice(idx, 1);
  next.unshift(item);
  return next;
}

export function moveInspectorSectionToBottom(
  section: InspectorInfoSection,
  order: readonly InspectorInfoSection[],
): InspectorInfoSection[] {
  const idx = order.indexOf(section);
  if (idx < 0 || idx === order.length - 1) return [...order];
  const next = [...order];
  const [item] = next.splice(idx, 1);
  next.push(item);
  return next;
}

export function stepInspectorSection(
  section: InspectorInfoSection,
  delta: number,
  visible: readonly InspectorInfoSection[],
  order: readonly InspectorInfoSection[],
): InspectorInfoSection[] {
  if (delta === 0) return [...order];
  const visIdx = visible.indexOf(section);
  if (visIdx < 0) return [...order];
  const targetVisIdx = visIdx + (delta > 0 ? 1 : -1);
  if (targetVisIdx < 0 || targetVisIdx >= visible.length) return [...order];
  return moveInspectorSection(section, visible[targetVisIdx], order);
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
