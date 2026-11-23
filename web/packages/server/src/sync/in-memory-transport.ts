import {
  GOOGLE_DRIVE_FOLDER_MIME_TYPE,
  type DriveAccountInfo,
  type DriveChange,
  type DriveChangePage,
  type RemoteDriveFile,
} from '@charkle/shared';
import {
  bytesToHex,
  bytesToStream,
  randomBytes,
  sha256HexSync,
  streamToBytes,
  utf8Decode,
} from '../runtime/web-crypto-utils.js';
import {
  DRIVE_ROOT_ID,
  DriveTransportError,
  validateDriveName,
  type DriveDownloadStreamResult,
  type DriveTransport,
} from './drive-transport.js';

interface StoredNode {
  meta: RemoteDriveFile;
  data?: Uint8Array;
}

/**
 * Full-fidelity in-memory streaming Drive transport with change feed for deterministic
 * multi-device sync, rename reconciliation, and storage migration tests (ZERO `node:*`).
 */
export class InMemoryDriveTransport implements DriveTransport {
  public readonly displayName: string;
  public readonly supportsChangesAPI = true;

  private readonly email: string;
  private readonly nodes = new Map<string, StoredNode>();
  private readonly changes: DriveChange[] = [];
  private idCounter = 1;

  constructor(opts: { displayName?: string; email?: string } = {}) {
    this.displayName = opts.displayName ?? 'InMemoryDrive';
    this.email = opts.email ?? 'test@charkle.local';
    this.nodes.set(DRIVE_ROOT_ID, {
      meta: {
        id: DRIVE_ROOT_ID,
        name: 'My Drive',
        mimeType: GOOGLE_DRIVE_FOLDER_MIME_TYPE,
        size: 0,
        modifiedTime: new Date().toISOString(),
        md5Checksum: null,
        parents: [],
        trashed: false,
        webViewLink: null,
      },
    });
  }

  private nextID(prefix: string): string {
    return `${prefix}-${this.idCounter++}-${bytesToHex(randomBytes(3))}`;
  }

  private recordChange(change: DriveChange): void {
    this.changes.push({
      fileID: change.fileID,
      removed: change.removed,
      file: change.file ? { ...change.file, parents: [...change.file.parents] } : null,
    });
  }

  async accountInfo(): Promise<DriveAccountInfo> {
    let used = 0;
    for (const node of this.nodes.values()) {
      if (!node.meta.trashed && node.data) used += node.data.byteLength;
    }
    return {
      email: this.email,
      displayName: this.displayName,
      storageUsedBytes: used,
      storageLimitBytes: 15 * 1024 * 1024 * 1024,
      source: 'memory',
    };
  }

  async resolveFolder(id: string): Promise<RemoteDriveFile> {
    const node = this.nodes.get(id);
    if (!node || node.meta.trashed || node.meta.mimeType !== GOOGLE_DRIVE_FOLDER_MIME_TYPE) {
      throw new DriveTransportError(`Folder not found: ${id}`, 'NOT_FOUND');
    }
    return { ...node.meta, parents: [...node.meta.parents] };
  }

  async findOrCreateFolder(name: string, parentID: string): Promise<RemoteDriveFile> {
    validateDriveName(name);
    if (!this.nodes.has(parentID)) {
      throw new DriveTransportError(`Parent folder not found: ${parentID}`, 'NOT_FOUND');
    }
    for (const node of this.nodes.values()) {
      if (
        !node.meta.trashed &&
        node.meta.mimeType === GOOGLE_DRIVE_FOLDER_MIME_TYPE &&
        node.meta.name === name &&
        node.meta.parents.includes(parentID)
      ) {
        return { ...node.meta, parents: [...node.meta.parents] };
      }
    }
    const id = this.nextID('fld');
    const meta: RemoteDriveFile = {
      id,
      name,
      mimeType: GOOGLE_DRIVE_FOLDER_MIME_TYPE,
      size: 0,
      modifiedTime: new Date().toISOString(),
      md5Checksum: null,
      parents: [parentID],
      trashed: false,
      webViewLink: null,
    };
    this.nodes.set(id, { meta });
    this.recordChange({ fileID: id, removed: false, file: meta });
    return { ...meta, parents: [...meta.parents] };
  }

  async listFiles(parentID: string): Promise<RemoteDriveFile[]> {
    const result: RemoteDriveFile[] = [];
    for (const node of this.nodes.values()) {
      if (!node.meta.trashed && node.meta.parents.includes(parentID)) {
        result.push({ ...node.meta, parents: [...node.meta.parents] });
      }
    }
    result.sort((a, b) => a.name.localeCompare(b.name));
    return result;
  }

  async uploadFile(opts: {
    data: Uint8Array | ReadableStream<Uint8Array>;
    size?: number;
    name: string;
    mimeType: string;
    parentID: string;
    existingFileID?: string | null;
  }): Promise<RemoteDriveFile> {
    validateDriveName(opts.name);
    const bytes =
      opts.data instanceof Uint8Array ? new Uint8Array(opts.data) : await streamToBytes(opts.data);
    const checksum = sha256HexSync(bytes).slice(0, 32);
    const now = new Date().toISOString();

    if (opts.existingFileID && this.nodes.has(opts.existingFileID)) {
      const node = this.nodes.get(opts.existingFileID)!;
      node.data = bytes;
      node.meta = {
        ...node.meta,
        name: opts.name,
        mimeType: opts.mimeType,
        size: bytes.byteLength,
        modifiedTime: now,
        md5Checksum: checksum,
        parents: [opts.parentID],
        trashed: false,
      };
      this.recordChange({ fileID: node.meta.id, removed: false, file: node.meta });
      return { ...node.meta, parents: [...node.meta.parents] };
    }

    for (const node of this.nodes.values()) {
      if (
        !node.meta.trashed &&
        node.meta.mimeType !== GOOGLE_DRIVE_FOLDER_MIME_TYPE &&
        node.meta.name === opts.name &&
        node.meta.parents.includes(opts.parentID)
      ) {
        node.data = bytes;
        node.meta = {
          ...node.meta,
          mimeType: opts.mimeType,
          size: bytes.byteLength,
          modifiedTime: now,
          md5Checksum: checksum,
        };
        this.recordChange({ fileID: node.meta.id, removed: false, file: node.meta });
        return { ...node.meta, parents: [...node.meta.parents] };
      }
    }

    const id = this.nextID('file');
    const meta: RemoteDriveFile = {
      id,
      name: opts.name,
      mimeType: opts.mimeType,
      size: bytes.byteLength,
      modifiedTime: now,
      md5Checksum: checksum,
      parents: [opts.parentID],
      trashed: false,
      webViewLink: null,
    };
    this.nodes.set(id, { meta, data: bytes });
    this.recordChange({ fileID: id, removed: false, file: meta });
    return { ...meta, parents: [...meta.parents] };
  }

  async downloadFile(fileID: string): Promise<Uint8Array> {
    const node = this.nodes.get(fileID);
    if (!node || node.meta.trashed || !node.data) {
      throw new DriveTransportError(`File not found: ${fileID}`, 'NOT_FOUND');
    }
    return new Uint8Array(node.data);
  }

  async downloadFileStream(fileID: string): Promise<DriveDownloadStreamResult> {
    const node = this.nodes.get(fileID);
    if (!node || node.meta.trashed || !node.data) {
      throw new DriveTransportError(`File not found: ${fileID}`, 'NOT_FOUND');
    }
    return {
      stream: bytesToStream(new Uint8Array(node.data)),
      size: node.data.byteLength,
      contentType: node.meta.mimeType,
    };
  }

  async moveOrRenameFile(opts: {
    fileID: string;
    newName?: string;
    newParentID?: string;
    previousParentID?: string;
  }): Promise<RemoteDriveFile> {
    const node = this.nodes.get(opts.fileID);
    if (!node || node.meta.trashed) {
      throw new DriveTransportError(`File not found: ${opts.fileID}`, 'NOT_FOUND');
    }
    if (opts.newName) validateDriveName(opts.newName);
    node.meta = {
      ...node.meta,
      name: opts.newName ?? node.meta.name,
      parents: opts.newParentID ? [opts.newParentID] : node.meta.parents,
      modifiedTime: new Date().toISOString(),
    };
    this.recordChange({ fileID: node.meta.id, removed: false, file: node.meta });
    return { ...node.meta, parents: [...node.meta.parents] };
  }

  async deleteFile(fileID: string): Promise<void> {
    const node = this.nodes.get(fileID);
    if (!node) return;
    node.meta.trashed = true;
    this.recordChange({ fileID, removed: true, file: node.meta });
  }

  async getStartPageToken(): Promise<string> {
    return String(this.changes.length);
  }

  async listChanges(pageToken: string): Promise<DriveChangePage> {
    const start = Math.max(0, Number.parseInt(pageToken, 10) || 0);
    const slice = this.changes.slice(start);
    return {
      changes: slice,
      nextPageToken: null,
      newStartPageToken: String(this.changes.length),
    };
  }

  readTextByPath(relPath: string): string | null {
    const file = this.findByPath(relPath);
    if (!file) return null;
    const node = this.nodes.get(file.id);
    return node?.data ? utf8Decode(node.data) : null;
  }

  findByPath(relPath: string): RemoteDriveFile | null {
    const parts = relPath.split('/').filter(Boolean);
    let parentID = DRIVE_ROOT_ID;
    let current: RemoteDriveFile | null = null;
    for (const part of parts) {
      let found: RemoteDriveFile | null = null;
      for (const node of this.nodes.values()) {
        if (!node.meta.trashed && node.meta.name === part && node.meta.parents.includes(parentID)) {
          found = node.meta;
          break;
        }
      }
      if (!found) return null;
      current = found;
      parentID = found.id;
    }
    return current;
  }
}
