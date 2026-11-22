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
  CreateApiTokenResult,
  DriveAccountInfo,
  DriveSyncConfig,
  LabColor,
  RemoteDriveFile,
  StorageMigrationReport,
  SyncReport,
  SyncStatus,
  ThumbnailTier,
  UUID,
} from '@charkle/shared';
import type { EventBus } from './api/events.js';
import type { LibraryDatabase } from './db/library-database.js';
import type { ConfigStore } from './storage/config-store.js';
import type { SecretVault } from './storage/secret-vault.js';

export interface MediaIngestResult {
  asset: AssetRecord;
  originalPath: string;
  vector?: AssetVector | null;
}

/**
 * Contract for the server-side media pipeline (thumbnails, originals, CIELAB, fingerprints, resolvers, LRU cache).
 */
export interface IMediaPipeline {
  readonly directory: string;
  readonly originalsDir: string;
  readonly thumbnailsDir: string;
  readonly previewsDir: string;
  readonly stagingDir: string;

  getThumbnailPath(id: UUID, tier?: ThumbnailTier): string | null;
  thumbnailTargetPath(id: UUID, tier?: ThumbnailTier): string;
  getOriginalPath(asset: AssetRecord): string | null;
  originalTargetPath(asset: AssetRecord): string;
  readThumbnailBuffer(id: UUID, tier?: ThumbnailTier): Promise<Buffer | null>;
  readOriginalBuffer(asset: AssetRecord): Promise<Buffer | null>;
  installOriginal(sourcePathOrBuffer: string | Buffer, asset: AssetRecord, moveSource?: boolean): Promise<string>;
  writeThumbnail(id: UUID, tier: ThumbnailTier, jpegBuffer: Buffer): Promise<string>;

  ingest(input: CaptureInput, folderID?: UUID | null, id?: UUID): Promise<MediaIngestResult>;
  ingestUploadedFile(
    buffer: Buffer,
    fileName: string,
    mimeType: string | null,
    folderID?: UUID | null,
    id?: UUID,
  ): Promise<MediaIngestResult>;
  refreshRichAsset(asset: AssetRecord): Promise<MediaIngestResult>;
  extractSocialMedia(postAsset: AssetRecord, attachmentIndex?: number | null): Promise<MediaIngestResult[]>;

  extractDominantColors(imageBuffer: Buffer, count?: number): Promise<LabColor[]>;
  computeVisualFingerprint(imageBuffer: Buffer): Promise<number[]>;
  generateThumbnailsFromBuffer(id: UUID, imageBuffer: Buffer): Promise<{ width: number; height: number }>;

  removeFiles(asset: AssetRecord): Promise<void>;
  removeFilesByIDs(ids: Iterable<UUID>): Promise<void>;

  getCacheStats(db: LibraryDatabase): Promise<CacheStats>;
  setCacheBudgetBytes(bytes: number): void;
  getCacheBudgetBytes(): number;
  evictCacheNow(db: LibraryDatabase): Promise<CacheStats>;
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
 * Contract for authentication, session management, PATs, and rate limiting.
 */
export interface IAuthService {
  readonly sessionCookieName: string;
  isInitialized(): boolean;
  bootstrapFromEnv(): AuthUser | null;
  setupAdmin(username: string, password: string, displayName?: string): AuthUser;
  login(
    username: string,
    password: string,
    opts: { rememberMe?: boolean; userAgent?: string | null; ipAddress?: string | null },
  ): { user: AuthUser; rawSessionToken: string; expiresAt: string; sessionID: UUID };
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
  ): void;
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
  db: LibraryDatabase;
  media: IMediaPipeline;
  sync: IDriveSyncEngine;
  configStore: ConfigStore;
  secretVault: SecretVault;
  auth: IAuthService;
  events: EventBus;
  dataDir: string;
}
