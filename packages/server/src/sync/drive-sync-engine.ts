import crypto from 'node:crypto';
import path from 'node:path';
import {
  activeStorageLocationSummary,
  canonicalSwiftJsonStringify,
  createDefaultSyncStatus,
  driveTransportModeLocalizedLabel,
  formatOpsShardFileName,
  GOOGLE_DRIVE_FOLDER_MIME_TYPE,
  isRemoteDriveFolder,
  parseOpsShardFileName,
  resolvedSharedFolderID,
  SwiftWireCodec,
  toSwiftUUID,
  type AssetRecord,
  type DriveAccountInfo,
  type DriveSyncConfig,
  type FolderRecord,
  type RemoteDriveFile,
  type StorageMigrationReport,
  type SyncLogLine,
  type SyncManifest,
  type SyncPhase,
  type SyncReport,
  type SyncStatus,
  type UUID,
} from '@charkle/shared';
import type { EventBus } from '../api/events.js';
import type { IDriveSyncEngine, IMediaPipeline } from '../context.js';
import type { LibraryDatabase } from '../db/library-database.js';
import { assetChangesTouchesLocation, stableUUID } from '../db/sync-operations.js';
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
import { LocalFolderTransport } from './local-folder-transport.js';
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
  }) {
    this.db = deps.db;
    this.media = deps.media;
    this.configStore = deps.configStore;
    this.secretVault = deps.secretVault;
    this.events = deps.events;
    this.googleOAuth = new GoogleOAuthClient(deps.secretVault);
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
    const saved = this.configStore.setSyncConfig(config);
    if (webDAVPassword !== undefined && webDAVPassword !== null && webDAVPassword.length > 0) {
      this.secretVault.set(SECRET_KEYS.WEBDAV_PASSWORD, webDAVPassword);
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
          throw new DriveTransportError('请先配置 gdirect 本地挂载路径。', 'NOT_CONFIGURED');
        }
        return new LocalFolderTransport(mountBase, 'gdirectMount');
      }
      case 'localOnly': {
        const base = path.dirname(path.resolve(config.localLibraryPath));
        return new LocalFolderTransport(base, 'LocalFolder');
      }
    }
  }

  private static resolvedRootPath(config: DriveSyncConfig): string {
    switch (config.mode) {
      case 'webDAV':
        return config.webDAVRemotePath || '/Charkle';
      case 'localOnly':
        return path.basename(path.resolve(config.localLibraryPath)) || 'Charkle';
      case 'directAPIWithGDirect':
      case 'gdirectMount':
        return config.rootFolderName || 'Charkle';
    }
  }

  async syncNow(): Promise<{ report: SyncReport; status: SyncStatus }> {
    const config = this.configStore.getSyncConfig();
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
      `正在连接 ${driveTransportModeLocalizedLabel(config.mode)}…`,
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
      this.updateProgress({ type: 'scanning' }, '正在扫描云端目录与文件变更…', 0.34);
      const inventory = await this.crawlHumanReadableInventory(transport, layout);
      this.updateProgress({ type: 'merging' }, '正在比对云端重命名与新增素材…', 0.46);
      const reconciled = await this.reconcileInventory(transport, layout, inventory);
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
        await this.uploadPhysicalChanges(transport, layout, pendingBeforeUpload);
      }

      // 4. Push local op shard (`ops-<device>-<endSeq>.jsonl`) encoded via SwiftWireCodec
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

    // Ensure `/.charkle/manifest.json` is written in Swift wire format
    const metaFiles = await transport.listFiles(metadata.id);
    const existingManifest = metaFiles.find((f) => f.name === 'manifest.json');
    const manifest: SyncManifest = {
      version: 1,
      rootFolderID: layout.root,
      directories: {
        inbox: layout.inbox,
        metadata: layout.metadata,
        ops: layout.ops,
        boards: layout.boards,
        embeddings: layout.embeddings,
        thumbnails: layout.thumbnails,
      },
    };
    const manifestJson = SwiftWireCodec.encodeManifest(manifest);
    if (!existingManifest) {
      await transport.uploadFile({
        data: Buffer.from(manifestJson, 'utf8'),
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
      const lines = SwiftWireCodec.decodeOpsJsonl(raw.toString('utf8'));
      let maxApplied = seenSeq;

      for (const line of lines) {
        if (line.seq <= seenSeq) continue;
        if (line.operation.change.type === 'vector' && !syncEmbeddings) {
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
  ): Promise<{ discoveredIDs: UUID[]; reconciledRenames: number }> {
    const discoveredIDs: UUID[] = [];
    let reconciledRenames = 0;

    // 1. Map remote folders -> local FolderRecords (reconciling renames too)
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
          if (local.name !== rf.name || (local.parentID ?? null) !== parentLocalID || local.driveFolderID !== remoteID) {
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
            const created: FolderRecord = {
              id,
              name: rf.name,
              parentID: parentLocalID,
              driveFolderID: remoteID,
              colorHex: null,
              customSymbol: null,
              sortOrder: this.db.fetchFolders().length,
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
      if (this.db.getState<boolean>(`deleted.drive.${remoteID}`)) continue;

      const parentRemote = rf.parents[0] ?? layout.inbox;
      const targetFolderID = resolvedFolderIDByRemote.get(parentRemote) ?? null;

      // Case A: Matched directly by driveFileID
      const existingByDrive = this.db.getAssetByDriveID(remoteID);
      if (existingByDrive) {
        const nameChanged = existingByDrive.fileName !== rf.name;
        const folderChanged = (existingByDrive.folderID ?? null) !== targetFolderID;
        if (nameChanged || folderChanged) {
          const oldStem = path.basename(existingByDrive.fileName, path.extname(existingByDrive.fileName));
          const newStem = path.basename(rf.name, path.extname(rf.name));
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
        continue;
      }

      // Case B / C: Download bytes to verify SHA-256 contentHash for rename reconciliation or discovery
      let bytes: Buffer;
      try {
        bytes = await transport.downloadFile(remoteID);
      } catch {
        continue;
      }
      const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');

      if (this.db.getState(`deleted.content.${sha256}`)) {
        continue;
      }

      // Match existing asset by contentHash whose old driveFileID is absent/unbound -> rename/re-upload tracking!
      const hashMatches = this.db.getAssetsByContentHash(sha256);
      const reconcilable = hashMatches.find(
        (a) => !a.driveFileID || !remoteFileIDs.has(a.driveFileID),
      );
      if (reconcilable) {
        const nameChanged = reconcilable.fileName !== rf.name;
        const folderChanged = (reconcilable.folderID ?? null) !== targetFolderID;
        const oldStem = path.basename(reconcilable.fileName, path.extname(reconcilable.fileName));
        const newStem = path.basename(rf.name, path.extname(rf.name));
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
      this.db.touchOriginal(ingested.asset.id);
      discoveredIDs.push(ingested.asset.id);
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

  private async uploadPhysicalChanges(
    transport: DriveTransport,
    layout: SyncLayout,
    pending: SyncLogLine[],
  ): Promise<void> {
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
            const buf = await this.media.readOriginalBuffer(asset);
            if (buf) {
              const uploaded = await transport.uploadFile({
                data: buf,
                name: asset.fileName,
                mimeType: asset.mimeType,
                parentID: targetParentID,
              });
              this.db.saveAssetLocally({ ...asset, driveFileID: uploaded.id }, false);
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
              // If remote file disappeared, re-upload if local original exists
              const buf = await this.media.readOriginalBuffer(asset);
              if (buf) {
                const uploaded = await transport.uploadFile({
                  data: buf,
                  name: asset.fileName,
                  mimeType: asset.mimeType,
                  parentID: targetParentID,
                });
                this.db.saveAssetLocally({ ...asset, driveFileID: uploaded.id }, false);
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
    const filtered = syncEmbeddings
      ? ops
      : ops.filter((line) => line.operation.change.type !== 'vector');
    const maxSeq = ops[ops.length - 1].seq;

    if (filtered.length > 0) {
      const device = this.db.deviceID();
      const shardName = formatOpsShardFileName(device, maxSeq);
      const jsonl = SwiftWireCodec.encodeOpsJsonl(filtered);
      await transport.uploadFile({
        data: Buffer.from(jsonl, 'utf8'),
        name: shardName,
        mimeType: 'application/x-ndjson',
        parentID: layout.ops,
      });
    }

    this.db.acknowledgeOps(maxSeq);
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
    const byName = new Map(remoteBoards.map((f) => [f.name, f]));
    let written = 0;

    for (const boardID of toSync) {
      const fileName = `${boardID}.json`;
      const board = this.db.getBoard(boardID);
      const existing = byName.get(fileName);
      if (board) {
        const json = SwiftWireCodec.stringifyMoodboardDocument(board);
        await transport.uploadFile({
          data: Buffer.from(json, 'utf8'),
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
    const byName = new Map(remoteThumbs.map((f) => [f.name, f]));

    // Upload dirty thumbnails
    const dirty = this.db.getState<Record<string, string>>('projection.thumbnails') ?? {};
    for (const [assetID, version] of Object.entries(dirty)) {
      const fileName = `${assetID}.jpg`;
      const existing = byName.get(fileName);
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

    // Download thumbnails for assets missing a local thumbnail
    for (const asset of this.db.fetchAssets({ includeTrashed: false })) {
      if (this.media.getThumbnailPath(asset.id, 'grid520')) continue;
      const remote = byName.get(`${asset.id}.jpg`);
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
    const dirty = this.db.getState<Record<string, string>>('projection.embeddings') ?? {};
    if (Object.keys(dirty).length === 0) return;

    const remoteFiles = await transport.listFiles(layout.embeddings);
    const byName = new Map(remoteFiles.map((f) => [f.name, f]));

    for (const [assetID, version] of Object.entries(dirty)) {
      const fileName = `${assetID}.json`;
      const existing = byName.get(fileName);
      const vec = this.db.getVector(assetID);
      if (vec && this.db.getAsset(assetID)) {
        const wire = canonicalSwiftJsonStringify(SwiftWireCodec.encodeAssetVector(vec));
        await transport.uploadFile({
          data: Buffer.from(wire, 'utf8'),
          name: fileName,
          mimeType: 'application/json',
          parentID: layout.embeddings,
          existingFileID: existing?.id ?? null,
        });
      } else if (existing) {
        await transport.deleteFile(existing.id).catch(() => undefined);
      }
      this.db.clearProjection('embeddings', assetID, version);
    }
  }

  private async fetchPinnedOriginals(transport: DriveTransport): Promise<void> {
    const protectedIDs = this.db.protectedAssetIDs();
    for (const id of protectedIDs) {
      const asset = this.db.getAsset(id);
      if (!asset || !asset.driveFileID) continue;
      if (this.media.getOriginalPath(asset)) continue;
      try {
        const bytes = await transport.downloadFile(asset.driveFileID);
        await this.media.installOriginal(bytes, asset);
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
    const cached = this.media.getOriginalPath(asset);
    if (cached) {
      this.db.touchOriginal(asset.id);
      return cached;
    }
    if (!asset.driveFileID) return null;
    const config = this.configStore.getSyncConfig();
    const transport = this.createTransportForConfig(config);
    const bytes = await transport.downloadFile(asset.driveFileID);
    const installed = await this.media.installOriginal(bytes, asset);
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
    const missingOriginals = allAssets.filter(
      (a) => a.driveFileID && !this.media.getOriginalPath(a),
    );
    if (missingOriginals.length > 0) {
      const sourceTransport = this.createTransportForConfig(sourceConfig);
      for (const asset of missingOriginals) {
        if (!asset.driveFileID) continue;
        const bytes = await sourceTransport.downloadFile(asset.driveFileID);
        await this.media.installOriginal(bytes, asset);
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

    // 4. Push complete library to target backend
    const targetTransport =
      targetTransportOverride ??
      this.createTransportForConfig(savedTarget, webDAVPassword);
    await this.syncWithTransport(targetTransport, savedTarget, {
      allowLocalFolderSync: true,
    });

    return {
      sourceMode: sourceConfig.mode,
      targetMode: savedTarget.mode,
      targetLocation: activeStorageLocationSummary(savedTarget),
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
    this.autoSyncTimer.unref();
  }

  stopAutoSync(): void {
    if (this.autoSyncTimer) {
      clearInterval(this.autoSyncTimer);
      this.autoSyncTimer = null;
    }
  }
}
