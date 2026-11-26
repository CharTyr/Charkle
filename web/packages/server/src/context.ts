import type {
  ApiTokenInfo,
  ApiTokenScope,
  AssetRecord,
  AssetVector,
  AuthSessionInfo,
  AuthStatus,
  AuthUser,
  CacheStats,
  CaptureInput,
  ClientPreprocessedMedia,
  CreateApiTokenResult,
  DriveAccountInfo,
  DriveSyncConfig,
  LabColor,
  RemoteDriveFile,
  RuntimeFeatures,
  RuntimeMode,
  StorageMigrationReport,
  SyncReport,
  SyncStatus,
  ThumbnailTier,
  UUID,
} from '@charkle/shared';
import type { EventBus } from './api/events.js';
import type { LibraryDatabase } from './db/library-database.js';
import type {
  BlobConditionalGetOptions,
  BlobConditionalStreamResult,
  BlobHeadResult,
  BlobRangeRequest,
  BlobStreamResult,
  IBlobStore,
  IBundleAssets,
  IImageProcessor,
  RuntimeEnv,
} from './runtime/types.js';
import type { BlobIndexSlot } from './db/library-database.js';
import type { ConfigStore } from './storage/config-store.js';
import type { SecretVault } from './storage/secret-vault.js';

export interface MediaIngestResult {
  asset: AssetRecord;
  /** Blob key (or absolute local file path on Node when available). */
  originalPath: string;
  vector?: AssetVector | null;
}

/**
 * Contract for the server-side media pipeline (thumbnails, originals, CIELAB, fingerprints, resolvers, LRU cache).
 * Backed by runtime-agnostic `IBlobStore` + `IImageProcessor` (zero direct `node:fs` or `sharp`).
 */
export interface IMediaPipeline {
  readonly blobs: IBlobStore;
  readonly images: IImageProcessor;

  /** Optional Node-only local path helpers (return `null` on remote/R2 blob stores). */
  getThumbnailPath(id: UUID, tier?: ThumbnailTier): string | null;
  thumbnailTargetPath(id: UUID, tier?: ThumbnailTier): string;
  getOriginalPath(asset: AssetRecord): string | null;
  cachedOriginalPath(asset: AssetRecord): string | null;
  originalTargetPath(asset: AssetRecord): string;

  /** Runtime-agnostic blob-store key & streaming accessors (work on both Node FS and Cloudflare R2). */
  originalBlobKey(asset: AssetRecord): string;
  findOriginalBlobKey(asset: AssetRecord): Promise<string | null>;
  findThumbnailBlobKey(
    id: UUID,
    tier?: ThumbnailTier,
  ): Promise<{ key: string; contentType: string } | null>;
  hasOriginal(asset: AssetRecord): Promise<boolean>;
  hasThumbnail(id: UUID, tier?: ThumbnailTier): Promise<boolean>;
  getThumbnailHead(
    id: UUID,
    tier?: ThumbnailTier,
  ): Promise<(BlobHeadResult & { key: string; contentType: string }) | null>;
  getThumbnailStream(
    id: UUID,
    tier?: ThumbnailTier,
  ): Promise<(BlobStreamResult & { key: string; contentType: string }) | null>;
  getThumbnailConditionalStream(
    id: UUID,
    tier?: ThumbnailTier,
    ifNoneMatch?: string,
  ): Promise<(BlobConditionalStreamResult & { key: string; contentType: string }) | null>;
  getOriginalHead(asset: AssetRecord): Promise<(BlobHeadResult & { key: string }) | null>;
  getOriginalStream(asset: AssetRecord, range?: BlobRangeRequest): Promise<BlobStreamResult | null>;
  getOriginalConditionalStream(
    asset: AssetRecord,
    options?: BlobConditionalGetOptions,
  ): Promise<(BlobConditionalStreamResult & { key: string }) | null>;
  resolveThumbnailKeyHint(
    id: UUID,
    tier?: ThumbnailTier,
  ): { key: string; contentType: string | null; fallbackKeys: string[] };
  resolveOriginalKeyHint(asset: AssetRecord): { key: string; indexed: boolean };
  recordBlobKey(
    assetID: UUID,
    slot: BlobIndexSlot,
    key: string,
    sizeBytes: number,
    contentType?: string | null,
  ): void;
  invalidateBlobKey(assetID: UUID, slot: BlobIndexSlot): void;

  readThumbnailBuffer(id: UUID, tier?: ThumbnailTier): Promise<Buffer | null>;
  readOriginalBuffer(asset: AssetRecord): Promise<Buffer | null>;
  installOriginal(
    data: Uint8Array | ReadableStream<Uint8Array> | string,
    asset: AssetRecord,
    moveSource?: boolean,
    knownSize?: number,
  ): Promise<string>;
  writeThumbnail(
    id: UUID,
    tier: ThumbnailTier,
    bytes: Uint8Array,
    mimeType?: string,
  ): Promise<string>;

  ingest(input: CaptureInput, folderID?: UUID | null, id?: UUID): Promise<MediaIngestResult>;
  ingestUploadedFile(
    data: Uint8Array,
    fileName: string,
    mimeType: string | null,
    folderID?: UUID | null,
    id?: UUID,
    preprocessed?: ClientPreprocessedMedia | null,
  ): Promise<MediaIngestResult>;
  finalizePrestoredOriginal(opts: {
    assetID: UUID;
    blobKey: string;
    fileName: string;
    mimeType: string | null;
    fileSizeBytes: number;
    folderID?: UUID | null;
    contentHash?: string | null;
    preprocessed?: ClientPreprocessedMedia | null;
  }): Promise<MediaIngestResult>;
  refreshRichAsset(asset: AssetRecord): Promise<MediaIngestResult>;
  hydrateImageMetadata(asset: AssetRecord): Promise<AssetRecord | null>;
  extractSocialMedia(
    postAsset: AssetRecord,
    attachmentIndex?: number | null,
  ): Promise<MediaIngestResult[]>;

  extractDominantColors(imageBuffer: Uint8Array, count?: number): Promise<LabColor[]>;
  computeVisualFingerprint(imageBuffer: Uint8Array): Promise<number[]>;
  generateThumbnailsFromBuffer(
    id: UUID,
    imageBuffer: Uint8Array,
    mimeType?: string,
  ): Promise<{ width: number; height: number }>;

  removeFiles(asset: AssetRecord): Promise<void>;
  removeFilesByIDs(ids: Iterable<UUID>): Promise<void>;

  getCacheStats(db: LibraryDatabase): Promise<CacheStats>;
  setCacheBudgetBytes(bytes: number): void;
  getCacheBudgetBytes(): number;
  evictCacheNow(
    db: LibraryDatabase,
    keepingIDs?: ReadonlySet<UUID>,
    options?: { skipStats?: boolean },
  ): Promise<CacheStats>;
}

/**
 * Contract for the multi-backend Drive/WebDAV/Local sync engine.
 */
export interface IDriveSyncEngine {
  getStatus(): SyncStatus;
  getConfig(): DriveSyncConfig;
  updateConfig(config: DriveSyncConfig, webDAVPassword?: string | null): Promise<SyncStatus>;
  syncNow(): Promise<{ report: SyncReport; status: SyncStatus }>;
  downloadOriginal(asset: AssetRecord): Promise<string | null>;
  testWebDAV(config: DriveSyncConfig, password?: string | null): Promise<DriveAccountInfo>;
  listSharedGoogleDriveFolders(): Promise<RemoteDriveFile[]>;
  startGoogleOAuth(redirectUri: string): { authURL: string; state: string };
  completeGoogleOAuth(code: string, state: string, redirectUri: string): Promise<DriveAccountInfo>;
  signOutGoogle(): Promise<void>;
  migrateStorage(
    targetConfig: DriveSyncConfig,
    webDAVPassword?: string | null,
  ): Promise<StorageMigrationReport>;
  startAutoSync(): void;
  stopAutoSync(): void;
}

export interface AuthenticatedPrincipal {
  user: AuthUser;
  authType: 'session' | 'token';
  sessionID?: UUID;
  tokenID?: UUID;
  scopes?: ApiTokenScope[];
}

/**
 * Contract for authentication, session management, PATs, and password hashing.
 */
export interface IAuthService {
  readonly sessionCookieName: string;
  isInitialized(): boolean;
  bootstrapFromEnv(env?: RuntimeEnv): Promise<AuthUser | null>;
  bootstrapFromEnvSync?(env?: RuntimeEnv): AuthUser | null;
  setupAdmin(username: string, password: string, displayName?: string): Promise<AuthUser>;
  login(
    username: string,
    password: string,
    opts: { rememberMe?: boolean; userAgent?: string | null; ipAddress?: string | null },
  ): Promise<{ user: AuthUser; rawSessionToken: string; expiresAt: string; sessionID: UUID }>;
  verifySessionToken(rawToken: string): AuthenticatedPrincipal | null;
  verifyApiToken(rawToken: string): AuthenticatedPrincipal | null;
  getAuthStatus(principal: AuthenticatedPrincipal | null): AuthStatus;
  logoutSession(sessionID: UUID): void;
  listSessions(userID: UUID, currentSessionID?: UUID): AuthSessionInfo[];
  revokeSession(userID: UUID, sessionID: UUID): boolean;
  revokeOtherSessions(userID: UUID, currentSessionID?: UUID): number;
  changePassword(
    userID: UUID,
    currentPassword: string,
    newPassword: string,
    currentSessionID?: UUID,
  ): Promise<void>;
  listApiTokens(userID: UUID): ApiTokenInfo[];
  createApiToken(
    userID: UUID,
    name: string,
    scopes: ApiTokenScope[],
    expiresInDays?: number | null,
  ): CreateApiTokenResult;
  revokeApiToken(userID: UUID, tokenID: UUID): boolean;
}

/**
 * Shared dependency container passed to all route registrars (`routes-core.ts`, `routes-ai.ts`, MCP server).
 */
export interface ServerContext {
  runtimeMode: RuntimeMode;
  features: RuntimeFeatures;
  db: LibraryDatabase;
  blobs: IBlobStore;
  images: IImageProcessor;
  bundles: IBundleAssets;
  media: IMediaPipeline;
  sync: IDriveSyncEngine;
  configStore: ConfigStore;
  secretVault: SecretVault;
  auth: IAuthService;
  events: EventBus;
  dataDir: string;
  env?: RuntimeEnv;
  /** Optional Node-only local file helpers for MCP stdio / `fileURL` ingest. */
  localFs?: {
    existsSync(filePath: string): boolean;
    resolvePath(filePath: string): string;
    writeFileSync(filePath: string, data: Uint8Array): void;
  };
}
