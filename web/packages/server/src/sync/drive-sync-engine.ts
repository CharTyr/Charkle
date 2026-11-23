import {
  activeStorageLocationSummary,
  createDefaultSyncStatus,
  decodeBytesBase64,
  driveTransportModeLocalizedLabel,
  encodeBytesBase64,
  formatOpsShardFileName,
  isRemoteDriveFolder,
  parseOpsShardFileName,
  resolvedSharedFolderID,
  SwiftWireCodec,
  toSwiftUUID,
  type AssetRecord,
  type AssetVector,
  type DriveAccountInfo,
  type DriveSyncConfig,
  type EmbeddingPrecision,
  type FolderRecord,
  type RemoteDriveFile,
  type RuntimeMode,
  type StorageMigrationReport,
  type SyncLogLine,
  type SyncManifest,
  type SyncOperation,
  type SyncPhase,
  type SyncReport,
  type SyncStatus,
  type UUID,
} from '@charkle/shared';
import type { EventBus } from '../api/events.js';
import type { IDriveSyncEngine, IMediaPipeline } from '../context.js';
import {
  decodeEmbeddingBlob,
  encodeEmbeddingBlob,
  type LibraryDatabase,
} from '../db/library-database.js';
import { assetChangesTouchesLocation, stableUUID } from '../db/sync-operations.js';
import { encodeBinaryPlist, isBinaryPlist, parseBinaryPlist, type PlistValue } from '../runtime/bplist.js';
import type { LocalTransportFactory, RuntimeEnv } from '../runtime/types.js';
import {
  posixBasename,
  posixExtname,
  posixStripExt,
  sha256HexSync,
  utf8Decode,
  utf8Encode,
} from '../runtime/web-crypto-utils.js';
import type { ConfigStore } from '../storage/config-store.js';
import { SECRET_KEYS, type SecretVault } from '../storage/secret-vault.js';
import { DirectAPITransport } from './direct-api-transport.js';
import {
  DRIVE_ROOT_ID,
  DriveTransportError,
  validateDriveName,
  type DriveTransport,
} from './drive-transport.js';
import { GoogleOAuthClient } from './google-oauth.js';
import { WebDAVTransport } from './webdav-transport.js';

interface SyncLayout {
  root: string;
  inbox: string;
  metadata: string;
  ops: string;
  boards: string;
  embeddings: string;
  thumbnails: string;
}

interface CrawledInventory {
  /** All non-folder files in human-readable folders (excluding `.charkle/`). */
  files: Map<string, RemoteDriveFile>;
  /** All human-readable subfolders under root (excluding `.charkle/` and `Inbox`). */
  folders: Map<string, RemoteDriveFile>;
}

export class DriveSyncEngine implements IDriveSyncEngine {
  private readonly db: LibraryDatabase;
  private readonly media: IMediaPipeline;
  private readonly configStore: ConfigStore;
  private readonly secretVault: SecretVault;
  private readonly events: EventBus;
  private readonly runtimeMode: RuntimeMode;
  private readonly localTransportFactory?: LocalTransportFactory;
  public readonly googleOAuth: GoogleOAuthClient;

  private status: SyncStatus;
  private running = false;
  private autoSyncTimer: ReturnType<typeof setInterval> | null = null;
  private customTransportOverride: DriveTransport | null = null;

  constructor(deps: {
    db: LibraryDatabase;
    media: IMediaPipeline;
    configStore: ConfigStore;
    secretVault: SecretVault;
    events: EventBus;
    transportOverride?: DriveTransport;
    localTransportFactory?: LocalTransportFactory;
    runtimeMode?: RuntimeMode;
    env?: RuntimeEnv;
  }) {
    this.db = deps.db;
    this.media = deps.media;
    this.configStore = deps.configStore;
    this.secretVault = deps.secretVault;
    this.events = deps.events;
    this.runtimeMode = deps.runtimeMode ?? 'node';
    this.localTransportFactory = deps.localTransportFactory;
    this.googleOAuth = new GoogleOAuthClient(deps.secretVault, {
      stateStore: deps.db,
      env: deps.env,
    });
    this.customTransportOverride = deps.transportOverride ?? null;

    const saved = this.db.getState<SyncStatus>('lastSyncStatus');
    const cfg = this.configStore.getSyncConfig();
    this.status = createDefaultSyncStatus({
      ...(saved ?? {}),
      phase: { type: 'idle' },
      activeMode: cfg.mode,
      pendingOpCount: this.db.pendingOpCount(),
    });
  }

  getStatus(): SyncStatus {
    return {
      ...this.status,
      pendingOpCount: this.db.pendingOpCount(),
    };
  }

  getConfig(): DriveSyncConfig {
    return this.configStore.getSyncConfig();
  }

  async updateConfig(
    config: DriveSyncConfig,
    webDAVPassword?: string | null,
  ): Promise<SyncStatus> {
    if (config.rootFolderName) {
      const segs = config.rootFolderName
        .split('/')
        .map((s) => s.trim())
        .filter(Boolean);
      for (const seg of segs) {
        if (seg === '.' || seg === '..' || seg.startsWith('.')) {
          throw new DriveTransportError(`无效的同步根目录名：${config.rootFolderName}`, 'INVALID_CONFIG');
        }
        validateDriveName(seg);
      }
    }
    if (config.webDAVRemotePath) {
      const segs = config.webDAVRemotePath
        .split('/')
        .map((s) => s.trim())
        .filter(Boolean);
      for (const seg of segs) {
        if (seg === '.' || seg === '..') {
          throw new DriveTransportError(`无效的 WebDAV 远程路径：${config.webDAVRemotePath}`, 'INVALID_CONFIG');
        }
        validateDriveName(seg);
      }
    }

    const saved = this.configStore.setSyncConfig(config);
    if (webDAVPassword !== undefined && webDAVPassword !== null) {
      if (webDAVPassword.length === 0) {
        this.secretVault.delete(SECRET_KEYS.WEBDAV_PASSWORD);
      } else {
        this.secretVault.set(SECRET_KEYS.WEBDAV_PASSWORD, webDAVPassword);
      }
    }
    this.status.activeMode = saved.mode;
    this.status.lastError = null;
    this.broadcastStatus();
    if (this.autoSyncTimer) {
      this.stopAutoSync();
      this.startAutoSync();
    }
    return this.getStatus();
  }

  private updateProgress(phase: SyncPhase, detail: string | null, progress: number | null): void {
    this.status.phase = phase;
    this.status.currentDetail = detail;
    this.status.progressFraction =
      progress === null ? null : Math.max(0, Math.min(1, progress));
    this.status.pendingOpCount = this.db.pendingOpCount();
    this.broadcastStatus();
  }

  private broadcastStatus(): void {
    this.events.emitSyncStatus(this.getStatus());
  }

  public createTransportForConfig(
    config: DriveSyncConfig,
    explicitWebDAVPassword?: string | null,
  ): DriveTransport {
    if (this.customTransportOverride) {
      return this.customTransportOverride;
    }
    switch (config.mode) {
      case 'directAPIWithGDirect':
        return new DirectAPITransport(this.googleOAuth);
      case 'webDAV': {
        const password =
          explicitWebDAVPassword ?? this.secretVault.get(SECRET_KEYS.WEBDAV_PASSWORD) ?? '';
        return new WebDAVTransport({
          serverURL: config.webDAVServerURL,
          username: config.webDAVUsername,
          password,
        });
      }
      case 'gdirectMount': {
        const mountBase = config.mountPath.trim();
        if (!mountBase) {
          throw new DriveTransportError('请先配置本地挂载路径。', 'NOT_CONFIGURED');
        }
        if (!this.localTransportFactory) {
          throw new DriveTransportError('当前云端运行环境不支持本地磁盘挂载。', 'UNSUPPORTED_MODE');
        }
        return this.localTransportFactory(config);
      }
      case 'localOnly': {
        if (!this.localTransportFactory) {
          throw new DriveTransportError('当前使用内置云存储，无需同步外部本地文件夹。', 'LOCAL_ONLY');
        }
        return this.localTransportFactory(config);
      }
    }
  }

  private static resolvedRootPath(config: DriveSyncConfig): string {
    switch (config.mode) {
      case 'webDAV':
        return config.webDAVRemotePath || '/Charkle';
      case 'localOnly':
        return posixBasename(config.localLibraryPath) || 'Charkle';
      case 'directAPIWithGDirect':
      case 'gdirectMount':
        return config.rootFolderName || 'Charkle';
    }
  }

  async syncNow(): Promise<{ report: SyncReport; status: SyncStatus }> {
    const config = this.configStore.getSyncConfig();
    if (config.mode === 'localOnly' && !this.customTransportOverride && !this.localTransportFactory) {
      return {
        report: {
          uploadedOps: 0,
          downloadedOps: 0,
          discoveredRemoteAssets: 0,
          discoveredAssetIDs: [],
          updatedBoards: 0,
          reconciledRenames: 0,
          durationSeconds: 0,
        },
        status: this.getStatus(),
      };
    }
    const transport = this.createTransportForConfig(config);
    const report = await this.syncWithTransport(transport, config, {
      allowLocalFolderSync: config.mode === 'localOnly',
    });
    return { report, status: this.getStatus() };
  }

  async syncWithTransport(
    transport: DriveTransport,
    config: DriveSyncConfig,
    opts: { allowLocalFolderSync?: boolean } = {},
  ): Promise<SyncReport> {
    if (config.mode === 'localOnly' && !opts.allowLocalFolderSync) {
      return {
        uploadedOps: 0,
        downloadedOps: 0,
        discoveredRemoteAssets: 0,
        discoveredAssetIDs: [],
        updatedBoards: 0,
        reconciledRenames: 0,
        durationSeconds: 0,
      };
    }
    if (this.running) {
      throw new DriveTransportError('当前已有同步任务正在运行，请稍候。', 'SYNC_IN_PROGRESS');
    }

    this.running = true;
    const startMs = Date.now();
    this.status.activeMode = config.mode;
    this.status.lastError = null;
    this.updateProgress(
      { type: 'scanning' },
      `正在连接 ${driveTransportModeLocalizedLabel(config.mode, this.runtimeMode)}…`,
      0.05,
    );

    try {
      const account = await transport.accountInfo();
      this.status.account = account;

      this.updateProgress({ type: 'scanning' }, '正在检查云端目录结构…', 0.12);
      const sharedRootID =
        config.mode === 'directAPIWithGDirect' ? resolvedSharedFolderID(config) : null;
      const rootPath = DriveSyncEngine.resolvedRootPath(config);
      const layout = await this.ensureLayout(transport, rootPath, sharedRootID);
      const scope = `remote.${stableUUID(`${transport.displayName}:${account.email}:${layout.root}`)}`;

      const report: SyncReport = {
        uploadedOps: 0,
        downloadedOps: 0,
        discoveredRemoteAssets: 0,
        discoveredAssetIDs: [],
        updatedBoards: 0,
        reconciledRenames: 0,
        durationSeconds: 0,
      };

      // 1. Pull remote op shards first (CRDT merge)
      this.updateProgress(
        { type: 'downloading', completed: 0, total: 0 },
        '正在拉取其他设备的变更日志…',
        0.2,
      );
      const pulled1 = await this.pullRemoteOps(transport, layout, scope, config.syncEmbeddings);
      report.downloadedOps += pulled1.downloadedOps;
      const changedBoards = new Set<UUID>(pulled1.changedBoards);

      // 2. Crawl human-readable remote inventory and reconcile renames/moves/discoveries
      // Collect pending local mutations BEFORE inventory reconciliation so local renames/moves are NEVER reverted (`P0-13`)
      const pendingBeforeReconcile = this.db.pendingOps(10_000);
      this.updateProgress({ type: 'scanning' }, '正在扫描云端目录与文件变更…', 0.34);
      const inventory = await this.crawlHumanReadableInventory(transport, layout);
      this.updateProgress({ type: 'merging' }, '正在比对云端重命名与新增素材…', 0.46);
      const reconciled = await this.reconcileInventory(
        transport,
        layout,
        inventory,
        pendingBeforeReconcile,
      );
      report.discoveredRemoteAssets += reconciled.discoveredIDs.length;
      report.discoveredAssetIDs.push(...reconciled.discoveredIDs);
      report.reconciledRenames += reconciled.reconciledRenames;

      // 3. Upload pending physical files/folders for local ops
      const pendingBeforeUpload = this.db.pendingOps(10_000);
      if (pendingBeforeUpload.length > 0) {
        this.updateProgress(
          { type: 'uploading', completed: 0, total: pendingBeforeUpload.length },
          '正在同步本地文件与文件夹…',
          0.6,
        );
        await this.uploadPhysicalChanges(transport, layout, pendingBeforeUpload, inventory);
      }

      // 4. Push local op shards (`ops-<device>-<endSeq>.jsonl`, max 200 ops/shard) encoded via SwiftWireCodec
      const readyOps = this.db.pendingOps(10_000);
      if (readyOps.length > 0) {
        this.updateProgress(
          { type: 'uploading', completed: 0, total: readyOps.length },
          '正在上传同步操作日志…',
          0.76,
        );
        const published = await this.pushLocalOps(
          transport,
          layout,
          readyOps,
          config.syncEmbeddings,
        );
        report.uploadedOps += published;
        for (const line of readyOps) {
          if (line.operation.change.type === 'board') {
            changedBoards.add(toSwiftUUID(line.operation.change.delta.id));
          } else if (line.operation.change.type === 'deleteBoard') {
            changedBoards.add(toSwiftUUID(line.operation.change.id));
          }
        }
        // Post-push pull pass (matching macOS DriveSyncEngine) to catch concurrent peer ops
        const pulled2 = await this.pullRemoteOps(transport, layout, scope, config.syncEmbeddings);
        report.downloadedOps += pulled2.downloadedOps;
        for (const bid of pulled2.changedBoards) changedBoards.add(bid);
      }

      // 5. Project changed boards, thumbnails, and embeddings into `/.charkle/`
      this.updateProgress({ type: 'merging' }, '正在同步情绪板、缩略图与向量索引…', 0.88);
      const boardsWritten = await this.syncBoardsProjection(transport, layout, changedBoards);
      report.updatedBoards = Math.max(changedBoards.size, boardsWritten);

      if (config.syncThumbnails) {
        await this.syncThumbnailsProjection(transport, layout);
      }
      if (config.syncEmbeddings) {
        await this.syncEmbeddingsProjection(transport, layout);
      }

      // 6. Fetch pinned offline originals if missing locally + clean up deleted media
      await this.fetchPinnedOriginals(transport);
      await this.cleanupDeletedMedia();

      report.durationSeconds = Math.round(((Date.now() - startMs) / 1000) * 1000) / 1000;
      this.status.lastSyncedAt = new Date().toISOString();
      this.status.lastError = null;
      this.status.pendingOpCount = this.db.pendingOpCount();
      this.status.phase = { type: 'idle' };
      this.status.currentDetail = null;
      this.status.progressFraction = null;
      this.db.setState('lastSyncStatus', this.status);
      this.events.emitSyncCompleted(report, this.getStatus());

      if (
        report.downloadedOps > 0 ||
        report.discoveredRemoteAssets > 0 ||
        report.reconciledRenames > 0
      ) {
        this.events.emitLibraryChanged('sync', report.discoveredAssetIDs);
      }
      if (report.updatedBoards > 0) {
        for (const bid of changedBoards) this.events.emitBoardUpdated(bid);
      }

      return report;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this.status.phase = { type: 'error', message: msg };
      this.status.lastError = msg;
      this.status.currentDetail = msg;
      this.status.progressFraction = null;
      this.broadcastStatus();
      throw err;
    } finally {
      this.running = false;
    }
  }

  private async ensureLayout(
    transport: DriveTransport,
    rootPath: string,
    sharedRootID: string | null,
  ): Promise<SyncLayout> {
    let rootFile: RemoteDriveFile;
    if (sharedRootID) {
      rootFile = await transport.resolveFolder(sharedRootID);
    } else {
      const segs = rootPath
        .split('/')
        .map((s) => s.trim())
        .filter((s) => s && s !== '.' && s !== '..');
      const finalSegs = segs.length > 0 ? segs : ['Charkle'];
      let parentID = DRIVE_ROOT_ID;
      let last: RemoteDriveFile | null = null;
      for (const seg of finalSegs) {
        validateDriveName(seg);
        last = await transport.findOrCreateFolder(seg, parentID);
        parentID = last.id;
      }
      rootFile = last!;
    }

    const inbox = await transport.findOrCreateFolder('Inbox', rootFile.id);
    const metadata = await transport.findOrCreateFolder('.charkle', rootFile.id);
    const ops = await transport.findOrCreateFolder('ops', metadata.id);
    const boards = await transport.findOrCreateFolder('boards', metadata.id);
    const embeddings = await transport.findOrCreateFolder('embeddings', metadata.id);
    const thumbnails = await transport.findOrCreateFolder('thumbnails', metadata.id);

    const layout: SyncLayout = {
      root: rootFile.id,
      inbox: inbox.id,
      metadata: metadata.id,
      ops: ops.id,
      boards: boards.id,
      embeddings: embeddings.id,
      thumbnails: thumbnails.id,
    };

    // Ensure `/.charkle/manifest.json` is validated & written in Swift wire format (`directories.Inbox`)
    const metaFiles = await transport.listFiles(metadata.id);
    const existingManifest = metaFiles.find((f) => f.name === 'manifest.json');
    if (existingManifest) {
      try {
        const raw = await transport.downloadFile(existingManifest.id);
        const decoded = SwiftWireCodec.decodeManifest(utf8Decode(raw));
        if (decoded.version !== 1) {
          throw new DriveTransportError(
            `不支持的同步清单版本 v${decoded.version}，请升级 Charkle。`,
            'UNSUPPORTED_MANIFEST_VERSION',
          );
        }
      } catch (err) {
        if (err instanceof DriveTransportError) throw err;
      }
    } else {
      const manifest: SyncManifest = {
        version: 1,
        rootFolderID: layout.root,
        directories: {
          Inbox: layout.inbox,
          ops: layout.ops,
          boards: layout.boards,
          embeddings: layout.embeddings,
          thumbnails: layout.thumbnails,
        },
      };
      const manifestJson = SwiftWireCodec.encodeManifest(manifest);
      await transport.uploadFile({
        data: utf8Encode(manifestJson),
        name: 'manifest.json',
        mimeType: 'application/json',
        parentID: metadata.id,
      });
    }

    return layout;
  }

  private async pullRemoteOps(
    transport: DriveTransport,
    layout: SyncLayout,
    scope: string,
    syncEmbeddings: boolean,
  ): Promise<{ downloadedOps: number; changedBoards: Set<UUID> }> {
    const myDevice = this.db.deviceID();
    const files = await transport.listFiles(layout.ops);

    // Replay previously deferred disabled.vector.* ops if syncEmbeddings was re-enabled
    if (syncEmbeddings) {
      const disabledVectors = this.db.getStatesWithPrefix<SyncOperation>('disabled.vector.');
      for (const item of disabledVectors) {
        try {
          this.db.applySyncOperation(item.value);
        } catch {
          // ignore stale deferred vector
        }
        this.db.setState(item.key, null);
      }
    }

    const shards: Array<{ file: RemoteDriveFile; device: string; endSeq: number }> = [];
    for (const file of files) {
      const parsed = parseOpsShardFileName(file.name);
      if (!parsed) continue;
      if (parsed.device === myDevice) continue;
      shards.push({ file, device: parsed.device, endSeq: parsed.endSeq });
    }
    shards.sort((a, b) => a.endSeq - b.endSeq || a.device.localeCompare(b.device));

    let downloadedOps = 0;
    const changedBoards = new Set<UUID>();

    for (const shard of shards) {
      const stateKey = `${scope}.deviceSeq.${shard.device}`;
      const seenSeq = this.db.getState<number>(stateKey) ?? 0;
      if (shard.endSeq <= seenSeq) continue;

      const raw = await transport.downloadFile(shard.file.id);
      const lines = SwiftWireCodec.decodeOpsJsonl(utf8Decode(raw));
      let maxApplied = seenSeq;

      for (const line of lines) {
        if (line.seq <= seenSeq) continue;
        if (line.operation.change.type === 'vector' && !syncEmbeddings) {
          this.db.setState(`disabled.vector.${toSwiftUUID(line.operation.change.id)}`, line.operation);
          maxApplied = Math.max(maxApplied, line.seq);
          continue;
        }
        this.db.applySyncOperation(line.operation);
        downloadedOps++;
        maxApplied = Math.max(maxApplied, line.seq);

        if (line.operation.change.type === 'board') {
          changedBoards.add(toSwiftUUID(line.operation.change.delta.id));
        } else if (line.operation.change.type === 'deleteBoard') {
          changedBoards.add(toSwiftUUID(line.operation.change.id));
        }
      }
      if (maxApplied > seenSeq) {
        this.db.setState(stateKey, maxApplied);
      }
    }

    return { downloadedOps, changedBoards };
  }

  private async crawlHumanReadableInventory(
    transport: DriveTransport,
    layout: SyncLayout,
  ): Promise<CrawledInventory> {
    const files = new Map<string, RemoteDriveFile>();
    const folders = new Map<string, RemoteDriveFile>();

    const queue: string[] = [layout.root];
    const visited = new Set<string>([layout.metadata]);

    while (queue.length > 0) {
      const parentID = queue.shift()!;
      if (visited.has(parentID)) continue;
      visited.add(parentID);

      const children = await transport.listFiles(parentID);
      for (const child of children) {
        if (child.id === layout.metadata || child.name === '.charkle') continue;
        if (isRemoteDriveFolder(child)) {
          if (child.id !== layout.inbox) {
            folders.set(child.id, child);
          }
          queue.push(child.id);
        } else {
          files.set(child.id, child);
        }
      }
    }

    return { files, folders };
  }

  private async reconcileInventory(
    transport: DriveTransport,
    layout: SyncLayout,
    inventory: CrawledInventory,
    pendingOps: readonly SyncLogLine[] = [],
  ): Promise<{ discoveredIDs: UUID[]; reconciledRenames: number }> {
    const discoveredIDs: UUID[] = [];
    let reconciledRenames = 0;

    // Collect pending local mutation guards BEFORE reconciling remote state (`P0-13`)
    const pendingAssetMoves = new Set<UUID>();
    const pendingFolderMutations = new Set<UUID>();
    const pendingDeletedDriveIDs = new Set<string>();
    for (const line of pendingOps) {
      const ch = line.operation.change;
      if (
        ch.type === 'asset' &&
        line.operation.projectLocation !== false &&
        assetChangesTouchesLocation(ch.delta)
      ) {
        pendingAssetMoves.add(toSwiftUUID(ch.delta.id));
      } else if (ch.type === 'folder') {
        pendingFolderMutations.add(toSwiftUUID(ch.folder.id));
      } else if ((ch.type === 'deleteAsset' || ch.type === 'deleteFolder') && ch.driveID) {
        pendingDeletedDriveIDs.add(ch.driveID);
      }
    }

    // 1. Map remote folders -> local FolderRecords (respecting pending local folder renames/moves!)
    const folderByDriveID = new Map<string, FolderRecord>();
    const allLocalFolders = this.db.fetchFolders();
    for (const f of allLocalFolders) {
      if (f.driveFolderID) folderByDriveID.set(f.driveFolderID, f);
    }

    // BFS topological order from root so parentID is always mapped before child
    const resolvedFolderIDByRemote = new Map<string, UUID | null>();
    resolvedFolderIDByRemote.set(layout.root, null);
    resolvedFolderIDByRemote.set(layout.inbox, null);

    let progress = true;
    while (progress) {
      progress = false;
      for (const [remoteID, rf] of inventory.folders.entries()) {
        if (resolvedFolderIDByRemote.has(remoteID)) continue;
        if (pendingDeletedDriveIDs.has(remoteID)) {
          resolvedFolderIDByRemote.set(remoteID, null);
          progress = true;
          continue;
        }
        const parentRemoteID = rf.parents[0] ?? layout.root;
        if (!resolvedFolderIDByRemote.has(parentRemoteID)) continue;
        const parentLocalID = resolvedFolderIDByRemote.get(parentRemoteID) ?? null;

        let local = folderByDriveID.get(remoteID);
        if (!local) {
          // Match by parent + name if unbound
          local = this.db
            .fetchFolders()
            .find(
              (f) =>
                (f.parentID ?? null) === parentLocalID &&
                f.name.toLowerCase() === rf.name.toLowerCase(),
            );
        }
        if (local) {
          if (pendingFolderMutations.has(local.id)) {
            // Do NOT revert pending local rename/move — only bind driveFolderID if missing
            if (local.driveFolderID !== remoteID) {
              const bound: FolderRecord = { ...local, driveFolderID: remoteID };
              this.db.putFolder(bound);
              folderByDriveID.set(remoteID, bound);
            }
          } else if (
            local.name !== rf.name ||
            (local.parentID ?? null) !== parentLocalID ||
            local.driveFolderID !== remoteID
          ) {
            const updated: FolderRecord = {
              ...local,
              name: rf.name,
              parentID: parentLocalID,
              driveFolderID: remoteID,
              updatedAt: new Date().toISOString(),
            };
            this.db.putFolder(updated);
            folderByDriveID.set(remoteID, updated);
          }
          resolvedFolderIDByRemote.set(remoteID, local.id);
        } else {
          const id = stableUUID(`folder:${remoteID}`);
          if (!this.db.isTombstoned('folder', id)) {
            const now = new Date().toISOString();
            const existingFolders = this.db.fetchFolders();
            const maxSort = existingFolders.reduce((m, f) => Math.max(m, f.sortOrder), -1);
            const created: FolderRecord = {
              id,
              name: rf.name,
              parentID: parentLocalID,
              driveFolderID: remoteID,
              colorHex: null,
              customSymbol: null,
              sortOrder: maxSort + 1,
              assetCount: 0,
              createdAt: now,
              updatedAt: now,
            };
            this.db.putFolder(created);
            folderByDriveID.set(remoteID, created);
            resolvedFolderIDByRemote.set(remoteID, created.id);
          } else {
            resolvedFolderIDByRemote.set(remoteID, null);
          }
        }
        progress = true;
      }
    }

    // 2. Reconcile remote files against local assets
    const remoteFileIDs = new Set(inventory.files.keys());

    for (const [remoteID, rf] of inventory.files.entries()) {
      if (pendingDeletedDriveIDs.has(remoteID)) {
        continue;
      }
      // Tombstone remote cleanup (`P0-15`)
      if (
        this.db.getState<boolean>(`deleted.drive.${remoteID}`) ||
        (rf.md5Checksum && this.db.getState<boolean>(`deleted.md5.${rf.md5Checksum.toLowerCase()}`))
      ) {
        await transport.deleteFile(remoteID).catch(() => undefined);
        continue;
      }

      const parentRemote = rf.parents[0] ?? layout.inbox;
      const targetFolderID = resolvedFolderIDByRemote.get(parentRemote) ?? null;

      // Case A: Matched directly by driveFileID
      const existingByDrive = this.db.getAssetByDriveID(remoteID);
      if (existingByDrive) {
        if (!pendingAssetMoves.has(existingByDrive.id)) {
          const nameChanged = existingByDrive.fileName !== rf.name;
          const folderChanged = (existingByDrive.folderID ?? null) !== targetFolderID;
          if (nameChanged || folderChanged) {
            const oldStem = posixStripExt(posixBasename(existingByDrive.fileName));
            const newStem = posixStripExt(posixBasename(rf.name));
            const updatedTitle =
              nameChanged && existingByDrive.title === oldStem ? newStem : existingByDrive.title;
            this.db.saveAssetLocally(
              {
                ...existingByDrive,
                title: updatedTitle,
                fileName: rf.name,
                folderID: targetFolderID,
                updatedAt: new Date().toISOString(),
              },
              false,
            );
            reconciledRenames++;
          }

          // Detect remote file content edit via md5Checksum / size change (`P0-15`)
          const remoteSig = `${rf.md5Checksum ?? ''}:${rf.size ?? ''}`;
          const prevSig = this.db.getState<string>(`remote.sig.${existingByDrive.id}`);
          const contentEdited =
            (rf.md5Checksum != null && prevSig != null && prevSig !== remoteSig) ||
            (rf.size != null &&
              rf.size > 0 &&
              existingByDrive.fileSizeBytes > 0 &&
              rf.size !== existingByDrive.fileSizeBytes &&
              prevSig !== remoteSig);
          if (contentEdited) {
            try {
              const latestBytes = await transport.downloadFile(remoteID);
              const latestSha = sha256HexSync(latestBytes);
              if (latestSha !== existingByDrive.contentHash) {
                const reingested = await this.media.ingestUploadedFile(
                  latestBytes,
                  rf.name,
                  rf.mimeType,
                  targetFolderID,
                  existingByDrive.id,
                );
                this.db.saveAssetLocally(
                  {
                    ...existingByDrive,
                    fileName: rf.name,
                    folderID: targetFolderID,
                    driveFileID: remoteID,
                    contentHash: reingested.asset.contentHash,
                    fileSizeBytes: reingested.asset.fileSizeBytes,
                    pixelWidth: reingested.asset.pixelWidth,
                    pixelHeight: reingested.asset.pixelHeight,
                    dominantColors: reingested.asset.dominantColors,
                    isLocalOriginalCached: true,
                    updatedAt: new Date().toISOString(),
                  },
                  false,
                );
                if (reingested.vector) {
                  this.db.saveVector(existingByDrive.id, reingested.vector);
                }
                this.db.markProjection('thumbnails', existingByDrive.id);
              }
            } catch {
              // ignore transient download error; retry next sync
            }
          }
          if (rf.md5Checksum != null || rf.size != null) {
            this.db.setState(`remote.sig.${existingByDrive.id}`, remoteSig);
          }
        }
        continue;
      }

      // Case B / C: Download bytes to verify SHA-256 contentHash for rename reconciliation or discovery
      let bytes: Uint8Array;
      try {
        bytes = await transport.downloadFile(remoteID);
      } catch {
        continue;
      }
      const sha256 = sha256HexSync(bytes);

      if (this.db.getState(`deleted.content.${sha256}`)) {
        await transport.deleteFile(remoteID).catch(() => undefined);
        continue;
      }

      // Match existing asset by contentHash whose old driveFileID is absent/unbound -> rename/re-upload tracking!
      const hashMatches = this.db.getAssetsByContentHash(sha256);
      const reconcilable = hashMatches.find(
        (a) => !a.driveFileID || !remoteFileIDs.has(a.driveFileID),
      );
      if (reconcilable) {
        if (pendingAssetMoves.has(reconcilable.id)) {
          this.db.saveAssetLocally({ ...reconcilable, driveFileID: remoteID }, false);
        } else {
          const nameChanged = reconcilable.fileName !== rf.name;
          const folderChanged = (reconcilable.folderID ?? null) !== targetFolderID;
          const oldStem = posixStripExt(posixBasename(reconcilable.fileName));
          const newStem = posixStripExt(posixBasename(rf.name));
          const updatedTitle =
            nameChanged && reconcilable.title === oldStem ? newStem : reconcilable.title;
          this.db.saveAssetLocally(
            {
              ...reconcilable,
              title: updatedTitle,
              fileName: rf.name,
              folderID: targetFolderID,
              driveFileID: remoteID,
              updatedAt: new Date().toISOString(),
            },
            false,
          );
          if (nameChanged || folderChanged) {
            reconciledRenames++;
          }
        }
        if (rf.md5Checksum != null || rf.size != null) {
          this.db.setState(
            `remote.sig.${reconcilable.id}`,
            `${rf.md5Checksum ?? ''}:${rf.size ?? ''}`,
          );
        }
        continue;
      }

      // Brand-new remote asset discovery
      const discoveredID = stableUUID(`asset:${remoteID}`);
      if (this.db.isTombstoned('asset', discoveredID) || this.db.getAsset(discoveredID)) {
        continue;
      }
      const ingested = await this.media.ingestUploadedFile(
        bytes,
        rf.name,
        rf.mimeType,
        targetFolderID,
        discoveredID,
      );
      ingested.asset.driveFileID = remoteID;
      this.db.saveAssetLocally(ingested.asset, false);
      if (ingested.vector) {
        this.db.saveVector(ingested.asset.id, ingested.vector);
      }
      if (rf.md5Checksum != null || rf.size != null) {
        this.db.setState(
          `remote.sig.${ingested.asset.id}`,
          `${rf.md5Checksum ?? ''}:${rf.size ?? ''}`,
        );
      }
      this.db.touchOriginal(ingested.asset.id);
      discoveredIDs.push(ingested.asset.id);
    }

    // 3. Remote deletion detection (`P0-15`): move previously cloud-bound local assets whose remote file disappeared to local Trash
    const localNonTrashed = this.db.fetchAssets({ includeTrashed: false });
    for (const asset of localNonTrashed) {
      if (!asset.driveFileID) continue;
      if (asset.driveFileID.startsWith('mounted-')) continue;
      if (remoteFileIDs.has(asset.driveFileID)) continue;
      if (pendingAssetMoves.has(asset.id)) continue;
      this.db.saveAssetLocally(
        {
          ...asset,
          isTrashed: true,
          driveFileID: null,
          updatedAt: new Date().toISOString(),
        },
        false,
      );
    }

    return { discoveredIDs, reconciledRenames };
  }

  private async ensureRemoteFolder(
    transport: DriveTransport,
    layout: SyncLayout,
    folderID: UUID | null | undefined,
  ): Promise<string> {
    if (!folderID) return layout.inbox;
    const folder = this.db.getFolder(folderID);
    if (!folder) return layout.inbox;
    if (folder.driveFolderID) return folder.driveFolderID;

    const parentRemoteID = folder.parentID
      ? await this.ensureRemoteFolder(transport, layout, folder.parentID)
      : layout.root;
    const created = await transport.findOrCreateFolder(folder.name, parentRemoteID);
    this.db.putFolder({ ...folder, driveFolderID: created.id });
    return created.id;
  }

  private resolveUploadFileName(
    asset: AssetRecord,
    targetParentID: string,
    usedNamesByParent: Map<string, Set<string>>,
  ): string {
    let used = usedNamesByParent.get(targetParentID);
    if (!used) {
      used = new Set<string>();
      usedNamesByParent.set(targetParentID, used);
    }
    const baseName = asset.fileName;
    if (!used.has(baseName.toLowerCase())) {
      used.add(baseName.toLowerCase());
      return baseName;
    }
    const ext = posixExtname(baseName);
    const stem = posixStripExt(baseName);
    const shortID = asset.id.slice(0, 8).toLowerCase();
    let candidate = `${stem}-${shortID}${ext}`;
    let counter = 2;
    while (used.has(candidate.toLowerCase())) {
      candidate = `${stem}-${shortID}-${counter}${ext}`;
      counter++;
    }
    used.add(candidate.toLowerCase());
    return candidate;
  }

  private async uploadPhysicalChanges(
    transport: DriveTransport,
    layout: SyncLayout,
    pending: SyncLogLine[],
    inventory?: CrawledInventory,
  ): Promise<void> {
    const usedNamesByParent = new Map<string, Set<string>>();
    if (inventory) {
      for (const rf of inventory.files.values()) {
        const parent = rf.parents[0] ?? layout.inbox;
        let set = usedNamesByParent.get(parent);
        if (!set) {
          set = new Set<string>();
          usedNamesByParent.set(parent, set);
        }
        set.add(rf.name.toLowerCase());
      }
    }

    let completed = 0;
    const total = pending.length;

    for (const line of pending) {
      const change = line.operation.change;
      switch (change.type) {
        case 'folder': {
          const folder = this.db.getFolder(change.folder.id);
          if (folder) {
            const parentRemoteID = folder.parentID
              ? await this.ensureRemoteFolder(transport, layout, folder.parentID)
              : layout.root;
            if (!folder.driveFolderID) {
              const created = await transport.findOrCreateFolder(folder.name, parentRemoteID);
              this.db.putFolder({ ...folder, driveFolderID: created.id });
            } else {
              try {
                const moved = await transport.moveOrRenameFile({
                  fileID: folder.driveFolderID,
                  newName: folder.name,
                  newParentID: parentRemoteID,
                });
                if (moved.id !== folder.driveFolderID) {
                  this.db.putFolder({ ...folder, driveFolderID: moved.id });
                }
              } catch {
                const created = await transport.findOrCreateFolder(folder.name, parentRemoteID);
                this.db.putFolder({ ...folder, driveFolderID: created.id });
              }
            }
          }
          break;
        }

        case 'asset': {
          const asset = this.db.getAsset(change.delta.id);
          if (!asset || asset.isTrashed) break;
          const targetParentID = await this.ensureRemoteFolder(
            transport,
            layout,
            asset.folderID,
          );
          if (!asset.driveFileID) {
            const streamRes = await this.media.getOriginalStream(asset);
            if (streamRes) {
              const uploadName = this.resolveUploadFileName(
                asset,
                targetParentID,
                usedNamesByParent,
              );
              const uploaded = await transport.uploadFile({
                data: streamRes.stream,
                size: streamRes.size,
                name: uploadName,
                mimeType: asset.mimeType,
                parentID: targetParentID,
              });
              const updatedAsset: AssetRecord = {
                ...asset,
                fileName: uploadName,
                driveFileID: uploaded.id,
              };
              this.db.saveAssetLocally(updatedAsset, false);
              if (uploaded.md5Checksum != null || uploaded.size != null) {
                this.db.setState(
                  `remote.sig.${asset.id}`,
                  `${uploaded.md5Checksum ?? ''}:${uploaded.size ?? ''}`,
                );
              }
            }
          } else if (
            line.operation.projectLocation !== false &&
            assetChangesTouchesLocation(change.delta)
          ) {
            try {
              const moved = await transport.moveOrRenameFile({
                fileID: asset.driveFileID,
                newName: asset.fileName,
                newParentID: targetParentID,
              });
              if (moved.id !== asset.driveFileID) {
                this.db.saveAssetLocally({ ...asset, driveFileID: moved.id }, false);
              }
            } catch {
              // If remote file disappeared, stream re-upload if local/R2 original exists
              const streamRes = await this.media.getOriginalStream(asset);
              if (streamRes) {
                const uploadName = this.resolveUploadFileName(
                  asset,
                  targetParentID,
                  usedNamesByParent,
                );
                const uploaded = await transport.uploadFile({
                  data: streamRes.stream,
                  size: streamRes.size,
                  name: uploadName,
                  mimeType: asset.mimeType,
                  parentID: targetParentID,
                });
                this.db.saveAssetLocally(
                  { ...asset, fileName: uploadName, driveFileID: uploaded.id },
                  false,
                );
              }
            }
          }
          break;
        }

        case 'deleteAsset': {
          if (change.driveID) {
            await transport.deleteFile(change.driveID).catch(() => undefined);
          }
          break;
        }

        case 'deleteFolder': {
          if (change.driveID) {
            await transport.deleteFile(change.driveID).catch(() => undefined);
          }
          break;
        }

        default:
          break;
      }
      completed++;
      this.updateProgress(
        { type: 'uploading', completed, total },
        `正在同步本地变更 (${completed}/${total})`,
        0.6 + 0.14 * (completed / Math.max(1, total)),
      );
    }
  }

  private async pushLocalOps(
    transport: DriveTransport,
    layout: SyncLayout,
    ops: SyncLogLine[],
    syncEmbeddings: boolean,
  ): Promise<number> {
    if (ops.length === 0) return 0;
    const filtered = syncEmbeddings
      ? ops
      : ops.filter((line) => line.operation.change.type !== 'vector');
    const ackSeq = ops[ops.length - 1].seq;

    if (filtered.length > 0) {
      const device = this.db.deviceID();
      const existingOpsFiles = await transport.listFiles(layout.ops).catch(() => []);
      const existingByName = new Map(existingOpsFiles.map((f) => [f.name, f]));

      // Chunk max 200 ops per shard matching macOS DriveSyncEngine, with shard endSeq === chunk.last.seq (`P0-12`)
      const CHUNK_SIZE = 200;
      for (let start = 0; start < filtered.length; start += CHUNK_SIZE) {
        const chunk = filtered.slice(start, start + CHUNK_SIZE);
        const chunkEndSeq = chunk[chunk.length - 1].seq;
        const shardName = formatOpsShardFileName(device, chunkEndSeq);
        const jsonl = SwiftWireCodec.encodeOpsJsonl(chunk);
        const existingShard = existingByName.get(shardName);
        await transport.uploadFile({
          data: utf8Encode(jsonl),
          name: shardName,
          mimeType: 'application/x-ndjson',
          parentID: layout.ops,
          existingFileID: existingShard?.id ?? null,
        });
      }
    }

    this.db.acknowledgeOps(ackSeq);
    return filtered.length;
  }

  private async syncBoardsProjection(
    transport: DriveTransport,
    layout: SyncLayout,
    changedBoards: Set<UUID>,
  ): Promise<number> {
    const dirty = this.db.getState<Record<string, string>>('projection.boards') ?? {};
    const toSync = new Set<UUID>([...changedBoards, ...Object.keys(dirty).map(toSwiftUUID)]);
    if (toSync.size === 0) return 0;

    const remoteBoards = await transport.listFiles(layout.boards);
    const byNameLower = new Map<string, RemoteDriveFile>();
    for (const f of remoteBoards) {
      const lower = f.name.toLowerCase();
      // Prefer exact lowercase filename if both exist
      if (!byNameLower.has(lower) || f.name === lower) {
        byNameLower.set(lower, f);
      }
    }
    let written = 0;

    for (const boardID of toSync) {
      // macOS Swift wire contract: lowercase UUID filename (`P0-10`)
      const fileName = `${boardID.toLowerCase()}.json`;
      const board = this.db.getBoard(boardID);
      const existing = byNameLower.get(fileName);
      if (board) {
        const json = SwiftWireCodec.stringifyMoodboardDocument(board);
        await transport.uploadFile({
          data: utf8Encode(json),
          name: fileName,
          mimeType: 'application/json',
          parentID: layout.boards,
          existingFileID: existing?.id ?? null,
        });
        written++;
      } else if (existing) {
        await transport.deleteFile(existing.id).catch(() => undefined);
      }
      if (dirty[boardID]) {
        this.db.clearProjection('boards', boardID, dirty[boardID]);
      }
    }
    return written;
  }

  private async syncThumbnailsProjection(
    transport: DriveTransport,
    layout: SyncLayout,
  ): Promise<void> {
    const remoteThumbs = await transport.listFiles(layout.thumbnails);
    const byNameLower = new Map<string, RemoteDriveFile>();
    for (const f of remoteThumbs) {
      const lower = f.name.toLowerCase();
      if (!byNameLower.has(lower) || f.name === lower) {
        byNameLower.set(lower, f);
      }
    }

    // Upload dirty thumbnails using lowercase UUID filenames (`P0-10`)
    const dirty = this.db.getState<Record<string, string>>('projection.thumbnails') ?? {};
    for (const [assetID, version] of Object.entries(dirty)) {
      const fileName = `${assetID.toLowerCase()}.jpg`;
      const existing = byNameLower.get(fileName);
      const asset = this.db.getAsset(assetID);
      if (!asset) {
        if (existing) await transport.deleteFile(existing.id).catch(() => undefined);
      } else {
        const buf = await this.media.readThumbnailBuffer(assetID, 'grid520');
        if (buf) {
          await transport.uploadFile({
            data: buf,
            name: fileName,
            mimeType: 'image/jpeg',
            parentID: layout.thumbnails,
            existingFileID: existing?.id ?? null,
          });
        }
      }
      this.db.clearProjection('thumbnails', assetID, version);
    }

    // Download thumbnails for assets missing a local thumbnail (defensively reads BOTH lowercase & uppercase!)
    for (const asset of this.db.fetchAssets({ includeTrashed: false })) {
      if (await this.media.hasThumbnail(asset.id, 'grid520')) continue;
      const remote = byNameLower.get(`${asset.id.toLowerCase()}.jpg`);
      if (!remote) continue;
      try {
        const buf = await transport.downloadFile(remote.id);
        await this.media.writeThumbnail(asset.id, 'grid520', buf);
      } catch {
        // ignore transient thumbnail fetch error
      }
    }
  }

  private async syncEmbeddingsProjection(
    transport: DriveTransport,
    layout: SyncLayout,
  ): Promise<void> {
    const remoteFiles = await transport.listFiles(layout.embeddings);
    const byNameLower = new Map<string, RemoteDriveFile>();
    for (const f of remoteFiles) {
      byNameLower.set(f.name.toLowerCase(), f);
    }

    const decodeShardEntry = (rawEntry: PlistValue): AssetVector | null => {
      if (!rawEntry || typeof rawEntry !== 'object' || Array.isArray(rawEntry) || rawEntry instanceof Uint8Array) {
        return null;
      }
      const dict = rawEntry as Record<string, PlistValue>;
      const precision: EmbeddingPrecision = dict.precision === 32 ? 32 : 16;
      const featurePrint =
        dict.feature instanceof Uint8Array && dict.feature.byteLength > 0
          ? encodeBytesBase64(dict.feature)
          : null;
      const embedding =
        dict.semantic instanceof Uint8Array && dict.semantic.byteLength > 0
          ? decodeEmbeddingBlob(dict.semantic, precision)
          : null;
      const embeddingModel = typeof dict.model === 'string' && dict.model.length > 0 ? dict.model : null;
      if (!featurePrint && !embedding) return null;
      return { featurePrint, embedding, embeddingModel, precision };
    };

    const encodeShardEntry = (vec: AssetVector): Record<string, PlistValue> => {
      const entry: Record<string, PlistValue> = {
        precision: vec.precision,
      };
      if (vec.featurePrint) {
        try {
          entry.feature = decodeBytesBase64(vec.featurePrint);
        } catch {
          // ignore malformed base64
        }
      }
      if (vec.embedding && vec.embedding.length > 0) {
        entry.semantic = encodeEmbeddingBlob(vec.embedding, vec.precision);
      }
      if (vec.embeddingModel) {
        entry.model = vec.embeddingModel;
      }
      return entry;
    };

    // 1. Push dirty local vectors into macOS-compatible 2-hex-prefix binary plist shards (`shard-<prefix>.bin`, `P0-11`)
    const dirty = this.db.getState<Record<string, string>>('projection.embeddings') ?? {};
    const dirtyEntries = Object.entries(dirty);
    if (dirtyEntries.length > 0) {
      const allVectors = this.db.getAllVectors();
      const grouped = new Map<string, Array<[string, string]>>();
      for (const [assetID, version] of dirtyEntries) {
        const prefix = assetID.toLowerCase().slice(0, 2);
        const list = grouped.get(prefix) ?? [];
        list.push([assetID, version]);
        grouped.set(prefix, list);
      }

      for (const [prefix, touched] of grouped.entries()) {
        const shardName = `shard-${prefix}.bin`;
        const existingFile = byNameLower.get(shardName);
        const shardDict: Record<string, PlistValue> = {};

        if (existingFile) {
          try {
            const raw = await transport.downloadFile(existingFile.id);
            if (isBinaryPlist(raw)) {
              const parsed = parseBinaryPlist(raw);
              if (parsed && typeof parsed === 'object' && !Array.isArray(parsed) && !(parsed instanceof Uint8Array)) {
                Object.assign(shardDict, parsed);
              }
            }
          } catch {
            // start fresh if remote shard unreadable
          }
        }

        // Merge all local vectors in this prefix + remove deleted assets
        for (const [vid, vec] of allVectors.entries()) {
          if (vid.toLowerCase().startsWith(prefix)) {
            shardDict[toSwiftUUID(vid)] = encodeShardEntry(vec);
          }
        }
        for (const [touchedID] of touched) {
          const uid = toSwiftUUID(touchedID);
          if (!allVectors.has(uid) || !this.db.getAsset(uid)) {
            delete shardDict[uid];
          }
        }

        const encodedBytes = encodeBinaryPlist(shardDict);
        await transport.uploadFile({
          data: encodedBytes,
          name: shardName,
          mimeType: 'application/octet-stream',
          parentID: layout.embeddings,
          existingFileID: existingFile?.id ?? null,
        });

        for (const [touchedID, version] of touched) {
          this.db.clearProjection('embeddings', touchedID, version);
        }
      }
    }

    // 2. Pull remote binary plist shards (`shard-<prefix>.bin`) for local assets missing vectors (`P0-11`)
    const existingVectors = this.db.getAllVectors();
    const assetsMissingVectors = this.db
      .fetchAssets({ includeTrashed: false })
      .filter((a) => !existingVectors.has(a.id));
    if (assetsMissingVectors.length === 0) return;

    const neededPrefixes = new Set(assetsMissingVectors.map((a) => a.id.toLowerCase().slice(0, 2)));
    for (const prefix of neededPrefixes) {
      const shardFile = byNameLower.get(`shard-${prefix}.bin`);
      if (!shardFile) continue;
      try {
        const raw = await transport.downloadFile(shardFile.id);
        if (!isBinaryPlist(raw)) continue;
        const parsed = parseBinaryPlist(raw);
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed) || parsed instanceof Uint8Array) {
          continue;
        }
        for (const [rawKey, rawVal] of Object.entries(parsed)) {
          const uid = toSwiftUUID(rawKey);
          if (existingVectors.has(uid)) continue;
          if (!this.db.getAsset(uid)) continue;
          const vec = decodeShardEntry(rawVal);
          if (vec) {
            this.db.saveVector(uid, vec);
            existingVectors.set(uid, vec);
          }
        }
      } catch {
        // ignore unreadable remote shard
      }
    }
  }

  private async downloadOriginalViaStream(
    transport: DriveTransport,
    asset: AssetRecord,
  ): Promise<string> {
    if (!asset.driveFileID) {
      throw new DriveTransportError('素材缺少云端文件 ID。', 'NOT_FOUND');
    }
    if (typeof transport.downloadFileStream === 'function') {
      const dl = await transport.downloadFileStream(asset.driveFileID);
      return this.media.installOriginal(dl.stream, asset);
    }
    const bytes = await transport.downloadFile(asset.driveFileID);
    return this.media.installOriginal(bytes, asset);
  }

  private async fetchPinnedOriginals(transport: DriveTransport): Promise<void> {
    const protectedIDs = this.db.protectedAssetIDs();
    for (const id of protectedIDs) {
      const asset = this.db.getAsset(id);
      if (!asset || !asset.driveFileID) continue;
      if (await this.media.hasOriginal(asset)) continue;
      try {
        await this.downloadOriginalViaStream(transport, asset);
        this.db.putAsset({ ...asset, isLocalOriginalCached: true });
        this.db.touchOriginal(asset.id);
      } catch {
        // retry on next sync
      }
    }
  }

  private async cleanupDeletedMedia(): Promise<void> {
    const cleanups = this.db.getStatesWithPrefix<boolean>('media.cleanup.');
    if (cleanups.length === 0) return;
    const ids = cleanups.map((c) => c.key.slice('media.cleanup.'.length));
    await this.media.removeFilesByIDs(ids);
    for (const c of cleanups) {
      this.db.setState(c.key, null);
    }
  }

  async downloadOriginal(asset: AssetRecord): Promise<string | null> {
    const existingKey = await this.media.findOriginalBlobKey(asset);
    if (existingKey) {
      this.db.touchOriginal(asset.id);
      return this.media.blobs.localFilePath?.(existingKey) ?? existingKey;
    }
    if (!asset.driveFileID) return null;
    const config = this.configStore.getSyncConfig();
    const transport = this.createTransportForConfig(config);
    const installed = await this.downloadOriginalViaStream(transport, asset);
    this.db.putAsset({ ...asset, isLocalOriginalCached: true });
    this.db.touchOriginal(asset.id);
    return installed;
  }

  // MARK: - Provider Helpers (WebDAV test, Google OAuth, Shared Folders)

  async testWebDAV(
    config: DriveSyncConfig,
    password?: string | null,
  ): Promise<DriveAccountInfo> {
    const resolvedPwd =
      password !== undefined && password !== null
        ? password
        : (this.secretVault.get(SECRET_KEYS.WEBDAV_PASSWORD) ?? '');
    const transport = new WebDAVTransport({
      serverURL: config.webDAVServerURL,
      username: config.webDAVUsername,
      password: resolvedPwd,
    });
    return transport.accountInfo();
  }

  async listSharedGoogleDriveFolders(): Promise<RemoteDriveFile[]> {
    const transport = new DirectAPITransport(this.googleOAuth);
    return transport.listSharedFolders();
  }

  startGoogleOAuth(redirectUri: string): { authURL: string; state: string } {
    return this.googleOAuth.startAuthorization(redirectUri);
  }

  async completeGoogleOAuth(
    code: string,
    state: string,
    redirectUri: string,
  ): Promise<DriveAccountInfo> {
    const account = await this.googleOAuth.exchangeCode(code, state, redirectUri);
    this.status.account = account;
    this.status.lastError = null;
    this.db.setState('lastSyncStatus', this.status);
    this.broadcastStatus();
    return account;
  }

  async signOutGoogle(): Promise<void> {
    this.googleOAuth.clearTokens();
    this.status.account = null;
    this.status.lastSyncedAt = null;
    this.status.phase = { type: 'idle' };
    this.db.setState('lastSyncStatus', this.status);
    this.broadcastStatus();
  }

  // MARK: - Lossless Two-Way Storage Migration

  async migrateStorage(
    targetConfig: DriveSyncConfig,
    webDAVPassword?: string | null,
    targetTransportOverride?: DriveTransport,
  ): Promise<StorageMigrationReport> {
    const startMs = Date.now();
    const sourceConfig = this.configStore.getSyncConfig();
    let downloadedOriginals = 0;

    // 1. Ensure all non-trashed originals are locally cached before leaving the source backend
    const allAssets = this.db.fetchAssets({ includeTrashed: false });
    const missingOriginals: AssetRecord[] = [];
    for (const a of allAssets) {
      if (a.driveFileID && !(await this.media.hasOriginal(a))) {
        missingOriginals.push(a);
      }
    }
    if (missingOriginals.length > 0) {
      const sourceTransport = this.createTransportForConfig(sourceConfig);
      for (const asset of missingOriginals) {
        if (!asset.driveFileID) continue;
        await this.downloadOriginalViaStream(sourceTransport, asset);
        this.db.putAsset({ ...asset, isLocalOriginalCached: true });
        this.db.touchOriginal(asset.id);
        downloadedOriginals++;
      }
    }

    // 2. Rebuild clean sync op queue from authoritative local DB state
    const requeued = this.db.requeueLibraryForBackendMigration(
      targetConfig.syncThumbnails,
      targetConfig.syncEmbeddings,
    );

    // 3. Persist target config & optional WebDAV password
    const savedTarget = this.configStore.setSyncConfig(targetConfig);
    if (webDAVPassword !== undefined && webDAVPassword !== null && webDAVPassword.length > 0) {
      this.secretVault.set(SECRET_KEYS.WEBDAV_PASSWORD, webDAVPassword);
    }

    // 4. Push complete library to target backend (skip remote push when switching to built-in cloud storage on Cloudflare)
    if (
      savedTarget.mode !== 'localOnly' ||
      targetTransportOverride ||
      this.customTransportOverride ||
      this.localTransportFactory
    ) {
      const targetTransport =
        targetTransportOverride ??
        this.createTransportForConfig(savedTarget, webDAVPassword);
      await this.syncWithTransport(targetTransport, savedTarget, {
        allowLocalFolderSync: true,
      });
    } else {
      this.status.activeMode = savedTarget.mode;
      this.status.lastError = null;
      this.status.phase = { type: 'idle' };
      this.db.setState('lastSyncStatus', this.status);
      this.broadcastStatus();
    }

    return {
      sourceMode: sourceConfig.mode,
      targetMode: savedTarget.mode,
      targetLocation: activeStorageLocationSummary(savedTarget, this.runtimeMode),
      downloadedOriginals,
      migratedAssets: requeued.assets,
      migratedFolders: requeued.folders,
      migratedBoards: requeued.boards,
      durationSeconds: Math.round(((Date.now() - startMs) / 1000) * 1000) / 1000,
    };
  }

  // MARK: - Auto Sync Loop

  startAutoSync(): void {
    this.stopAutoSync();
    const cfg = this.configStore.getSyncConfig();
    if (cfg.mode === 'localOnly' || cfg.autoSyncIntervalSeconds <= 0) return;
    const intervalMs = Math.max(15_000, cfg.autoSyncIntervalSeconds * 1000);
    this.autoSyncTimer = setInterval(() => {
      if (!this.running) {
        this.syncNow().catch(() => undefined);
      }
    }, intervalMs);
    if (typeof (this.autoSyncTimer as { unref?: () => void }).unref === 'function') {
      (this.autoSyncTimer as { unref: () => void }).unref();
    }
  }

  stopAutoSync(): void {
    if (this.autoSyncTimer) {
      clearInterval(this.autoSyncTimer);
      this.autoSyncTimer = null;
    }
  }
}
