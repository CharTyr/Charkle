import type { FolderRecord, ISODateString, UUID } from './core.js';
import type { AssetVector } from './media.js';
import type { BoardConnector, BoardNode, InkStroke } from './moodboard.js';

// MARK: - Storage & Transport Modes

export type RuntimeMode = 'node' | 'cloudflare';

export type DriveTransportMode =
  | 'directAPIWithGDirect'
  | 'webDAV'
  | 'gdirectMount'
  | 'localOnly';

export const DRIVE_TRANSPORT_MODES: readonly DriveTransportMode[] = [
  'directAPIWithGDirect',
  'webDAV',
  'gdirectMount',
  'localOnly',
] as const;

export function driveTransportModeLocalizedLabel(
  mode: DriveTransportMode,
  runtimeMode?: RuntimeMode,
): string {
  switch (mode) {
    case 'directAPIWithGDirect':
      return 'Google Drive';
    case 'webDAV':
      return 'WebDAV 云盘';
    case 'gdirectMount':
      return 'gdirect 本地挂载';
    case 'localOnly':
      return runtimeMode === 'cloudflare' ? '内置云存储' : '纯本地文件夹';
  }
}

export interface DriveAccountInfo {
  email: string;
  displayName?: string | null;
  storageUsedBytes?: number | null;
  storageLimitBytes?: number | null;
  source: string;
}

export interface GDirectEndpoint {
  ip: string;
  latencyMs: number;
  healthy: boolean;
}

export interface GDirectEnvironmentSnapshot {
  cliPath?: string | null;
  cliVersion?: string | null;
  appVersion?: string | null;
  hasVersionMismatch: boolean;
  rclonePath?: string | null;
  accounts: string[];
  defaultAccount?: string | null;
  endpoints: GDirectEndpoint[];
  mountPath: string;
  isMountActive: boolean;
  bypassTunEnabled: boolean;
}

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

export function createDefaultDriveSyncConfig(
  overrides: Partial<DriveSyncConfig> = {},
): DriveSyncConfig {
  return {
    mode: 'localOnly',
    rootFolderName: 'Charkle',
    sharedFolderURLOrID: '',
    mountPath: '',
    selectedGDirectAccount: null,
    useGDirectIPAcceleration: true,
    webDAVServerURL: '',
    webDAVUsername: '',
    webDAVRemotePath: '/Charkle',
    localLibraryPath: '.charkle-data/library',
    autoSyncIntervalSeconds: 120,
    syncThumbnails: true,
    syncEmbeddings: true,
    ...overrides,
  };
}

const VALID_DRIVE_ID_RE = /^[A-Za-z0-9_-]{4,128}$/;

function isValidDriveID(candidate: string): boolean {
  return VALID_DRIVE_ID_RE.test(candidate);
}

/**
 * Parses a Google Drive folder URL (`.../folders/<id>`, `...open?id=<id>`) or raw folder ID.
 * Exact port of Swift `DriveSyncConfig.extractGoogleDriveFolderID(from:)`.
 */
export function extractGoogleDriveFolderID(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;

  let parsedURL: URL | null = null;
  try {
    parsedURL = new URL(trimmed);
  } catch {
    parsedURL = null;
  }

  if (parsedURL && parsedURL.hostname.toLowerCase().includes('google.com')) {
    const parts = parsedURL.pathname.split('/').filter(Boolean);
    const foldersIdx = parts.indexOf('folders');
    if (foldersIdx >= 0 && foldersIdx + 1 < parts.length) {
      const candidate = parts[foldersIdx + 1];
      if (isValidDriveID(candidate)) return candidate;
    }
    const idVal = parsedURL.searchParams.get('id');
    if (idVal && isValidDriveID(idVal)) {
      return idVal;
    }
    return null;
  }

  if (!trimmed.includes('/') && !trimmed.includes(' ') && isValidDriveID(trimmed)) {
    return trimmed;
  }
  return null;
}

export function resolvedSharedFolderID(
  config: Pick<DriveSyncConfig, 'sharedFolderURLOrID'>,
): string | null {
  return extractGoogleDriveFolderID(config.sharedFolderURLOrID);
}

function trimSlashesAndSpaces(value: string): string {
  return value.replace(/^[/\s]+|[/\s]+$/g, '');
}

/**
 * Clean human-readable target path summary for the currently active storage backend.
 * Exact port of Swift `DriveSyncConfig.activeStorageLocationSummary`.
 */
export function activeStorageLocationSummary(
  config: DriveSyncConfig,
  runtimeMode?: RuntimeMode,
): string {
  switch (config.mode) {
    case 'directAPIWithGDirect': {
      const sharedID = resolvedSharedFolderID(config);
      if (sharedID) {
        const shortID = sharedID.slice(0, 10);
        return `Google Drive 共享目录 (${shortID}…)`;
      }
      const cleaned = trimSlashesAndSpaces(config.rootFolderName);
      return `Google Drive / ${cleaned || 'Charkle'}`;
    }
    case 'webDAV': {
      let host = config.webDAVServerURL;
      try {
        if (config.webDAVServerURL) {
          host = new URL(config.webDAVServerURL).hostname || config.webDAVServerURL;
        }
      } catch {
        host = config.webDAVServerURL;
      }
      const cleaned = trimSlashesAndSpaces(config.webDAVRemotePath);
      return `WebDAV (${host || '未配置'}) / ${cleaned || 'Charkle'}`;
    }
    case 'gdirectMount': {
      const cleaned = trimSlashesAndSpaces(config.rootFolderName);
      return `${config.mountPath}/${cleaned || 'Charkle'}`;
    }
    case 'localOnly':
      return runtimeMode === 'cloudflare' ? '内置云存储' : config.localLibraryPath;
  }
}

export const DriveSyncConfigUtils = {
  createDefault: createDefaultDriveSyncConfig,
  extractGoogleDriveFolderID,
  resolvedSharedFolderID,
  activeStorageLocationSummary,
} as const;

// MARK: - Migration, Sync Status & Reports

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

export type SyncPhase =
  | { type: 'idle' }
  | { type: 'scanning' }
  | { type: 'uploading'; completed: number; total: number }
  | { type: 'downloading'; completed: number; total: number }
  | { type: 'merging' }
  | { type: 'error'; message: string };

export interface SyncStatus {
  phase: SyncPhase;
  lastSyncedAt?: ISODateString | null;
  pendingOpCount: number;
  account?: DriveAccountInfo | null;
  activeMode: DriveTransportMode;
  lastError?: string | null;
  currentDetail?: string | null;
  progressFraction?: number | null;
}

export function createDefaultSyncStatus(overrides: Partial<SyncStatus> = {}): SyncStatus {
  return {
    phase: { type: 'idle' },
    lastSyncedAt: null,
    pendingOpCount: 0,
    account: null,
    activeMode: 'localOnly',
    lastError: null,
    currentDetail: null,
    progressFraction: null,
    ...overrides,
  };
}

export function isSyncStatusActive(status: Pick<SyncStatus, 'phase'>): boolean {
  switch (status.phase.type) {
    case 'scanning':
    case 'uploading':
    case 'downloading':
    case 'merging':
      return true;
    case 'idle':
    case 'error':
      return false;
  }
}

export function syncStatusLocalizedPhaseTitle(
  status: Pick<SyncStatus, 'phase' | 'lastSyncedAt'>,
): string {
  switch (status.phase.type) {
    case 'idle':
      return status.lastSyncedAt == null ? '等待同步' : '已同步';
    case 'scanning':
      return '正在扫描云端目录';
    case 'uploading':
      return status.phase.total > 0
        ? `正在上传 (${status.phase.completed}/${status.phase.total})`
        : '正在上传';
    case 'downloading':
      return status.phase.total > 0
        ? `正在拉取 (${status.phase.completed}/${status.phase.total})`
        : '正在拉取';
    case 'merging':
      return '正在整理与写入索引';
    case 'error':
      return '同步遇到异常';
  }
}

export interface SyncReport {
  uploadedOps: number;
  downloadedOps: number;
  discoveredRemoteAssets: number;
  discoveredAssetIDs: UUID[];
  updatedBoards: number;
  reconciledRenames: number;
  durationSeconds: number;
}

export function hasVisibleLibraryChanges(report: SyncReport): boolean {
  return (
    report.discoveredRemoteAssets > 0 ||
    report.downloadedOps > 0 ||
    report.reconciledRenames > 0 ||
    report.updatedBoards > 0
  );
}

// MARK: - Remote Drive File & Change Feed

export const GOOGLE_DRIVE_FOLDER_MIME_TYPE = 'application/vnd.google-apps.folder';

export interface RemoteDriveFile {
  id: string;
  name: string;
  mimeType: string;
  size?: number | null;
  modifiedTime?: ISODateString | null;
  md5Checksum?: string | null;
  parents: string[];
  trashed: boolean;
  webViewLink?: string | null;
}

export function isRemoteDriveFolder(file: Pick<RemoteDriveFile, 'mimeType'>): boolean {
  return file.mimeType === GOOGLE_DRIVE_FOLDER_MIME_TYPE;
}

export interface DriveChange {
  fileID: string;
  removed: boolean;
  file?: RemoteDriveFile | null;
}

export interface DriveChangePage {
  changes: DriveChange[];
  nextPageToken?: string | null;
  newStartPageToken?: string | null;
}

// MARK: - External Agent Policy

export type ExternalAgentAccessLevel = 'readOnly' | 'readWriteOrganize';

export const EXTERNAL_AGENT_ACCESS_LEVELS: readonly ExternalAgentAccessLevel[] = [
  'readOnly',
  'readWriteOrganize',
] as const;

export function externalAgentAccessLevelTitle(level: ExternalAgentAccessLevel): string {
  switch (level) {
    case 'readOnly':
      return '仅只读检索与导出';
    case 'readWriteOrganize':
      return '允许整理与生成情绪板';
  }
}

export function externalAgentAccessLevelSummary(level: ExternalAgentAccessLevel): string {
  switch (level) {
    case 'readOnly':
      return '外部 Agent 可检索素材、查看视觉联系表、读取情绪板与导出高清图，无法修改或写入素材库。';
    case 'readWriteOrganize':
      return '外部 Agent 可整理文件夹与标签、导入素材、生成或更新情绪板，并仅可将素材移入回收站（永不允许彻底删除）。';
  }
}

export interface ExternalAgentConfig {
  enabled: boolean;
  accessLevel: ExternalAgentAccessLevel;
}

export function createDefaultExternalAgentConfig(
  overrides: Partial<ExternalAgentConfig> = {},
): ExternalAgentConfig {
  return {
    enabled: true,
    accessLevel: 'readOnly',
    ...overrides,
  };
}

export function externalAgentAllowsRead(config: ExternalAgentConfig): boolean {
  return config.enabled;
}

export function externalAgentAllowsWrite(config: ExternalAgentConfig): boolean {
  return config.enabled && config.accessLevel === 'readWriteOrganize';
}

// MARK: - Sync Operation Log & Manifest Contracts (/.charkle/)

export interface SyncStamp {
  time: number;
  device: string;
}

export function compareSyncStamp(lhs: SyncStamp, rhs: SyncStamp): number {
  if (lhs.time !== rhs.time) return lhs.time < rhs.time ? -1 : 1;
  if (lhs.device !== rhs.device) return lhs.device < rhs.device ? -1 : 1;
  return 0;
}

export interface SyncClocks {
  clocks: Record<string, SyncStamp>;
}

export interface CollectionChanges<T extends { id: UUID }> {
  updated: T[];
  removed: UUID[];
}

export interface AssetChanges {
  id: UUID;
  /** Canonical Web field values (encoded as Base64 Swift JSON fragments on wire). */
  fields: Record<string, unknown>;
  tagsAdded: string[];
  tagsRemoved: string[];
}

export interface BoardChanges {
  id: UUID;
  /** Canonical Web field values (encoded as Base64 Swift JSON fragments on wire). */
  fields: Record<string, unknown>;
  nodes: CollectionChanges<BoardNode>;
  connectors: CollectionChanges<BoardConnector>;
  strokes: CollectionChanges<InkStroke>;
}

export type SyncOperationChange =
  | { type: 'asset'; delta: AssetChanges }
  | { type: 'board'; delta: BoardChanges }
  | { type: 'folder'; folder: FolderRecord }
  | { type: 'deleteAsset'; id: UUID; driveID?: string | null }
  | { type: 'deleteBoard'; id: UUID }
  | { type: 'deleteFolder'; id: UUID; driveID?: string | null }
  | { type: 'vector'; id: UUID; vector: AssetVector };

export interface SyncOperation {
  stamp: SyncStamp;
  change: SyncOperationChange;
  projectLocation?: boolean | null;
}

export interface SyncLogLine {
  seq: number;
  operation: SyncOperation;
}

export interface SyncManifest {
  version: number;
  rootFolderID?: string | null;
  directories?: Record<string, string> | null;
}

export interface DeletedAssetFingerprint {
  assetID: UUID;
  sha256: string;
  md5?: string | null;
  fileName: string;
  deletedAt: ISODateString;
}
