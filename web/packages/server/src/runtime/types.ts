import type {
  AssetRecord,
  DriveSyncConfig,
  FigmaBridgeBoardManifest,
  FigmaBridgeReport,
  GitHubRepoMetadata,
  LabColor,
  MoodboardDocument,
  MoodboardExportFormat,
  MoodboardExportOptions,
  NormalizedCropRect,
  SocialPostMetadata,
  ThumbnailTier,
  UUID,
} from '@charkle/shared';
import type { DriveTransport } from '../sync/drive-transport.js';

// MARK: - 1. Synchronous SQLite Seam (Node 26 DatabaseSync + Cloudflare DO ctx.storage.sql)

export type SqlParam = string | number | bigint | Uint8Array | null;

export interface ISqlDatabase {
  exec(sql: string): void;
  run(sql: string, params?: SqlParam[]): { changes: number; lastInsertRowid?: number | bigint };
  get<T = Record<string, unknown>>(sql: string, params?: SqlParam[]): T | undefined;
  all<T = Record<string, unknown>>(sql: string, params?: SqlParam[]): T[];
  transaction<T>(fn: () => T): T;
  close?(): void;
}

// MARK: - 2. Async Streaming Object Storage Seam (Local FS + Cloudflare R2)

export interface BlobRangeRequest {
  offset: number;
  length?: number;
}

export interface BlobStreamResult {
  stream: ReadableStream<Uint8Array>;
  size: number;
  contentType?: string;
  etag?: string;
  lastModifiedMs?: number;
  range?: { start: number; end: number; total: number };
}

export interface BlobHeadResult {
  size: number;
  contentType?: string;
  etag?: string;
  lastModifiedMs?: number;
}

export interface BlobListItem {
  key: string;
  size: number;
  lastModifiedMs?: number;
}

export interface IBlobStore {
  put(
    key: string,
    data: Uint8Array | ReadableStream<Uint8Array>,
    options?: { contentType?: string },
  ): Promise<{ size: number }>;
  getBytes(key: string): Promise<Uint8Array | null>;
  getStream(key: string, range?: BlobRangeRequest): Promise<BlobStreamResult | null>;
  head(key: string): Promise<BlobHeadResult | null>;
  delete(key: string): Promise<void>;
  list(prefix: string): Promise<BlobListItem[]>;
  /** Optional Node-only helper returning an existing absolute file path on disk (null if missing or remote). */
  localFilePath?(key: string): string | null;
  /** Optional Node-only helper returning the target absolute file path on disk (whether or not it exists yet). */
  targetFilePath?(key: string): string;
}

// MARK: - 3. Image Processing & Export Seam (Node sharp + Cloudflare Workers / Images binding)

export type ArtworkRenderRequest =
  | { kind: 'colorSwatch'; color: LabColor; title?: string }
  | { kind: 'textDocument'; title: string; badge: string; excerpt: string }
  | { kind: 'audioWaveform'; title: string; peaks: readonly number[]; durationSeconds: number | null }
  | { kind: 'model3D'; title: string; format: string }
  | { kind: 'githubRepo'; repo: GitHubRepoMetadata }
  | { kind: 'socialPost'; post: SocialPostMetadata; coverImageBytes?: Uint8Array | null }
  | { kind: 'webBookmark'; title: string; domain: string; description?: string | null }
  | { kind: 'genericBadge'; title: string; ext: string; kindLabel: string }
  | { kind: 'svg'; svg: string; width?: number; height?: number };

export interface RenderedCardResult {
  grid520: Uint8Array;
  preview1400?: Uint8Array;
  /** Full-size rendered card bytes (PNG on Node, SVG on Workers). */
  fullImage: Uint8Array;
  mimeType: string;
  width: number;
  height: number;
}

export interface GeneratedThumbnailsResult {
  grid520?: Uint8Array;
  preview1400?: Uint8Array;
  mimeType?: string;
  width?: number;
  height?: number;
}

export interface CropAndPadOptions {
  crop?: NormalizedCropRect | null;
  targetLongSide?: number;
  minSide?: number;
  maxSide?: number;
  quality?: number;
  padBackground?: string;
}

export interface ContactSheetItemInput {
  slot: number;
  asset: AssetRecord;
  thumbnailBytes?: Uint8Array | null;
  thumbnailPath?: string | null;
}

export interface ContactSheetRenderResult {
  data: Uint8Array;
  mimeType: 'image/png' | 'image/jpeg' | 'image/svg+xml';
  slotToAssetID: Map<number, UUID>;
  orderedSlots: Array<{ slot: number; assetID: UUID }>;
  width: number;
  height: number;
}

export interface MoodboardExportRequestParams {
  document: MoodboardDocument;
  assetsByID: ReadonlyMap<UUID, AssetRecord>;
  loadAssetBytes: (assetID: UUID, tier: ThumbnailTier) => Promise<Uint8Array | null>;
  format: MoodboardExportFormat;
  containerWidth?: number;
  options?: Partial<MoodboardExportOptions> & {
    backgroundMode?: 'light' | 'dark' | 'transparent';
  };
}

export interface FigmaBridgeExportRequestParams {
  document: MoodboardDocument;
  assetsByID: ReadonlyMap<UUID, AssetRecord>;
  containerWidth?: number;
  options?: Partial<MoodboardExportOptions>;
  loadOriginalBytes: (assetID: UUID) => Promise<{ bytes: Uint8Array; fileName?: string } | null>;
  loadThumbnailBytes: (assetID: UUID, tier: ThumbnailTier) => Promise<Uint8Array | null>;
}

export interface IImageProcessor {
  inspectDimensions(
    bytes: Uint8Array,
    mimeType?: string,
  ): Promise<{ width: number; height: number; format?: string } | null>;
  generateThumbnails(
    bytes: Uint8Array,
    mimeType: string,
  ): Promise<GeneratedThumbnailsResult>;
  extractColorsAndFingerprint(
    bytes: Uint8Array,
    mimeType?: string,
    options?: { crop?: NormalizedCropRect | null; count?: number },
  ): Promise<{ colors: LabColor[]; featurePrint?: Float32Array }>;
  renderArtworkCard(input: ArtworkRenderRequest): Promise<RenderedCardResult>;
  detectPrimarySubjectBox?(bytes: Uint8Array): Promise<NormalizedCropRect | null>;
  cropAndPad?(
    bytes: Uint8Array,
    opts?: CropAndPadOptions,
  ): Promise<{ data: Uint8Array; width: number; height: number; mimeType: string } | null>;
  renderContactSheet?(
    items: ContactSheetItemInput[],
    opts?: { maxCanvasWidth?: number; format?: 'png' | 'jpeg'; jpegQuality?: number },
  ): Promise<ContactSheetRenderResult | null>;
  exportMoodboardImage?(
    params: MoodboardExportRequestParams,
  ): Promise<{ data: Uint8Array; mimeType: string; width: number; height: number }>;
  exportFigmaBridgeZip?(
    params: FigmaBridgeExportRequestParams,
  ): Promise<{ zipBytes: Uint8Array; manifest: FigmaBridgeBoardManifest; report: FigmaBridgeReport }>;
}

// MARK: - 4. Downloadable Bundle Assets Seam (Extension ZIP + Figma Plugin ZIP)

export interface IBundleAssets {
  getExtensionZip(): Promise<Uint8Array | null>;
  getFigmaPluginZip(): Promise<Uint8Array | null>;
}

// MARK: - 5. Password Hashing Seam (Web Crypto PBKDF2-SHA256 + optional Node legacy scrypt verify)

export interface IPasswordHasher {
  hash(password: string): Promise<string>;
  verify(password: string, storedHash: string, legacySalt?: string): Promise<boolean>;
  /** Optional Node-only synchronous hash helper for sync env bootstrap. */
  hashSync?(password: string): string;
}

// MARK: - Runtime Environment & Optional Cloudflare Images Binding Structural Type

export type RuntimeEnv = Record<string, string | undefined>;

export type LocalTransportFactory = (config: DriveSyncConfig) => DriveTransport;

/**
 * Structural type matching Cloudflare Workers `ImagesBinding` (`env.IMAGES`)
 * without requiring `@cloudflare/workers-types` inside `@charkle/server`.
 */
export interface CloudflareImagesTransformResult {
  transform(options: {
    width?: number;
    height?: number;
    fit?: 'scale-down' | 'contain' | 'cover' | 'crop' | 'pad';
    background?: string;
    rotate?: number;
  }): CloudflareImagesTransformResult;
  output(options: {
    format: 'image/jpeg' | 'image/png' | 'image/webp' | 'image/avif';
    quality?: number;
  }): Promise<{ response(): Response }>;
}

export interface CloudflareImagesBinding {
  info?(stream: ReadableStream<Uint8Array>): Promise<{
    width?: number;
    height?: number;
    format?: string;
  }>;
  input(stream: ReadableStream<Uint8Array>): CloudflareImagesTransformResult;
}
