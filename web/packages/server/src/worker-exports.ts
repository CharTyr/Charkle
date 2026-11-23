/**
 * Cloudflare Workers-safe entrypoint for `@charkle/server`.
 *
 * STRICT GUARANTEE:
 * Importing this module (or anything transitively reachable from it) MUST NEVER
 * import `node:fs`, `node:fs/promises`, `node:sqlite`, `node:os`, `node:readline`,
 * `sharp`, `@hono/node-server`, or `local-folder-transport`.
 */

// Core runtime-agnostic app & context factory
export {
  createCoreApp,
  createRuntimeContext,
  defaultRuntimeFeatures,
  type AIRoutesRegistrar,
  type CreateCoreAppOptions,
  type CreateRuntimeContextOptions,
} from './core-app.js';

// Core context & middleware types
export type {
  AuthenticatedPrincipal,
  IAuthService,
  IDriveSyncEngine,
  IMediaPipeline,
  MediaIngestResult,
  ServerContext,
} from './context.js';
export type { AppVariables } from './api/middleware-auth.js';
export type { AIRouteOptions } from './api/routes-ai.js';

// Runtime abstraction seams & Workers-safe implementations
export type {
  ArtworkRenderRequest,
  BlobHeadResult,
  BlobListItem,
  BlobRangeRequest,
  BlobStreamResult,
  CloudflareImagesBinding,
  CloudflareImagesTransformResult,
  ContactSheetItemInput,
  ContactSheetRenderResult,
  CropAndPadOptions,
  FigmaBridgeExportRequestParams,
  GeneratedThumbnailsResult,
  IBlobStore,
  IBundleAssets,
  IImageProcessor,
  IPasswordHasher,
  ISqlDatabase,
  LocalTransportFactory,
  MoodboardExportRequestParams,
  RenderedCardResult,
  RuntimeEnv,
  SqlParam,
} from './runtime/types.js';
export {
  WorkersImageProcessor,
  inspectImageHeader,
  sniffImageMimeType,
  type ImageHeaderInfo,
  type WorkersImageProcessorOptions,
} from './runtime/workers-image.js';
export {
  PBKDF2_DEFAULT_ITERATIONS,
  PBKDF2_KEY_BYTES,
  PBKDF2_MAX_ITERATIONS,
  PBKDF2_SALT_BYTES,
  WebCryptoPasswordHasher,
  derivePbkdf2Sha256,
  type LegacyScryptVerifier,
  type WebCryptoPasswordHasherOptions,
} from './runtime/web-crypto-hash.js';
export {
  base64ToBytes,
  base64UrlToBytes,
  bytesToBase64,
  bytesToBase64Url,
  bytesToHex,
  hexToBytes,
  randomBytes,
  randomUUID,
  readEnv,
  sha256BytesAsync,
  sha256BytesSync,
  sha256HexAsync,
  sha256HexSync,
  streamToBytes,
  timingSafeEqualBytes,
  toArrayBuffer,
  utf8Decode,
  utf8Encode,
} from './runtime/web-crypto-utils.js';

// Database & vector helpers
export {
  LibraryDatabase,
  cosineSimilarity,
  decodeEmbeddingBlob,
  decodeFeaturePrintFloat32,
  encodeEmbeddingBlob,
  encodeFeaturePrintFloat32,
} from './db/library-database.js';

// Authentication & rate limiting
export {
  AuthError,
  AuthService,
  SESSION_COOKIE_NAME,
} from './auth/auth-service.js';
export {
  LoginRateLimiter,
  SlidingWindowRateLimiter,
  type RateLimitCheckResult,
} from './auth/rate-limiter.js';

// Media pipeline & sample library seeder
export {
  MediaPipeline,
  guessMimeType,
  sanitizeFileName,
  type MediaPipelineDeps,
} from './media/media-pipeline.js';
export { SampleLibrarySeeder, seedSampleLibrary } from './media/sample-seeder.js';

// Sync engine, OAuth & streaming transports (Google Drive API v3, WebDAV, In-Memory)
export { DriveSyncEngine } from './sync/drive-sync-engine.js';
export {
  DRIVE_ROOT_ID,
  DriveTransportError,
  validateDriveName,
  type DriveDownloadStreamResult,
  type DriveTransport,
} from './sync/drive-transport.js';
export { DirectAPITransport } from './sync/direct-api-transport.js';
export { WebDAVTransport, type WebDAVTransportOptions } from './sync/webdav-transport.js';
export { InMemoryDriveTransport } from './sync/in-memory-transport.js';
export {
  GoogleOAuthClient,
  type GoogleOAuthTokens,
  type OAuthStateStoreLike,
} from './sync/google-oauth.js';

// Storage, encrypted vault & realtime events
export {
  ConfigStore,
  DEFAULT_CACHE_BUDGET_BYTES,
  type ConfigStoreOptions,
  type PersistedConfigSnapshot,
} from './storage/config-store.js';
export {
  SECRET_KEYS,
  SecretVault,
  VAULT_SECRETS_STATE_KEY,
  type EncryptedVaultPayload,
  type SecretVaultOptions,
  type SyncVaultCryptoAdapter,
} from './storage/secret-vault.js';
export { EventBus } from './api/events.js';
