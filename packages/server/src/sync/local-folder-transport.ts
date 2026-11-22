import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import {
  GOOGLE_DRIVE_FOLDER_MIME_TYPE,
  type DriveAccountInfo,
  type RemoteDriveFile,
} from '@charkle/shared';
import { guessMimeType } from '../media/media-pipeline.js';
import {
  DRIVE_ROOT_ID,
  DriveTransportError,
  validateDriveName,
  type DriveTransport,
} from './drive-transport.js';

/**
 * Local filesystem / mounted volume transport (supports `localOnly` and `gdirectMount`).
 * Uses relative POSIX paths from `baseDir` as stable remote file IDs so paths are clean and portable.
 */
export class LocalFolderTransport implements DriveTransport {
  public readonly displayName: string;
  public readonly supportsChangesAPI = false;
  public readonly baseDir: string;

  constructor(baseDir: string, displayName = 'LocalFolder') {
    this.baseDir = path.resolve(baseDir);
    this.displayName = displayName;
    fs.mkdirSync(this.baseDir, { recursive: true });
  }

  private idToAbs(id: string): string {
    if (id === DRIVE_ROOT_ID || id === '' || id === '.') {
      return this.baseDir;
    }
    const clean = id.replace(/^mounted-/, '').replace(/^\/+/, '');
    const resolved = path.resolve(this.baseDir, clean);
    if (!resolved.startsWith(this.baseDir)) {
      throw new DriveTransportError(`Path escapes base directory: ${id}`, 'INVALID_PATH');
    }
    return resolved;
  }

  private absToID(absPath: string): string {
    const rel = path.relative(this.baseDir, absPath);
    if (!rel || rel === '.') return DRIVE_ROOT_ID;
    return rel.split(path.sep).join('/');
  }

  private parentIDOf(absPath: string): string {
    const parentAbs = path.dirname(absPath);
    if (path.resolve(absPath) === this.baseDir) return '';
    return this.absToID(parentAbs);
  }

  private async statToRemote(absPath: string): Promise<RemoteDriveFile> {
    const st = await fsp.stat(absPath);
    const id = this.absToID(absPath);
    const name = id === DRIVE_ROOT_ID ? path.basename(this.baseDir) : path.basename(absPath);
    const isDir = st.isDirectory();
    let md5: string | null = null;
    if (!isDir && st.size <= 32 * 1024 * 1024) {
      const buf = await fsp.readFile(absPath);
      md5 = crypto.createHash('md5').update(buf).digest('hex');
    }
    return {
      id,
      name,
      mimeType: isDir ? GOOGLE_DRIVE_FOLDER_MIME_TYPE : guessMimeType(name),
      size: isDir ? 0 : st.size,
      modifiedTime: st.mtime.toISOString(),
      md5Checksum: md5,
      parents: id === DRIVE_ROOT_ID ? [] : [this.parentIDOf(absPath)],
      trashed: false,
      webViewLink: null,
    };
  }

  async accountInfo(): Promise<DriveAccountInfo> {
    await fsp.mkdir(this.baseDir, { recursive: true });
    return {
      email: this.baseDir,
      displayName: path.basename(this.baseDir) || 'Local Library',
      storageUsedBytes: null,
      storageLimitBytes: null,
      source: 'local',
    };
  }

  async resolveFolder(id: string): Promise<RemoteDriveFile> {
    const abs = this.idToAbs(id);
    const st = await fsp.stat(abs).catch(() => null);
    if (!st || !st.isDirectory()) {
      throw new DriveTransportError(`Local folder not found: ${id}`, 'NOT_FOUND');
    }
    return this.statToRemote(abs);
  }

  async findOrCreateFolder(name: string, parentID: string): Promise<RemoteDriveFile> {
    validateDriveName(name);
    const parentAbs = this.idToAbs(parentID);
    const targetAbs = path.join(parentAbs, name);
    await fsp.mkdir(targetAbs, { recursive: true });
    return this.statToRemote(targetAbs);
  }

  async listFiles(parentID: string): Promise<RemoteDriveFile[]> {
    const parentAbs = this.idToAbs(parentID);
    let entries: fs.Dirent[];
    try {
      entries = await fsp.readdir(parentAbs, { withFileTypes: true });
    } catch {
      return [];
    }
    const list: RemoteDriveFile[] = [];
    for (const entry of entries) {
      if (entry.name === '.DS_Store' || entry.name.startsWith('._')) continue;
      if (!entry.isFile() && !entry.isDirectory()) continue;
      const abs = path.join(parentAbs, entry.name);
      try {
        list.push(await this.statToRemote(abs));
      } catch {
        // skip vanished entry
      }
    }
    list.sort((a, b) => a.name.localeCompare(b.name));
    return list;
  }

  async uploadFile(opts: {
    data: Buffer;
    name: string;
    mimeType: string;
    parentID: string;
    existingFileID?: string | null;
  }): Promise<RemoteDriveFile> {
    validateDriveName(opts.name);
    const parentAbs = this.idToAbs(opts.parentID);
    await fsp.mkdir(parentAbs, { recursive: true });
    const targetAbs = path.join(parentAbs, opts.name);
    // Write directly without O_EXCL so NFS / rclone mounts work cleanly (matching DriveFiles.swift)
    await fsp.writeFile(targetAbs, opts.data);
    if (opts.existingFileID) {
      const prevAbs = this.idToAbs(opts.existingFileID);
      if (path.resolve(prevAbs) !== path.resolve(targetAbs)) {
        await fsp.unlink(prevAbs).catch(() => undefined);
      }
    }
    return this.statToRemote(targetAbs);
  }

  async downloadFile(fileID: string): Promise<Buffer> {
    const abs = this.idToAbs(fileID);
    try {
      return await fsp.readFile(abs);
    } catch {
      throw new DriveTransportError(`Local file not found: ${fileID}`, 'NOT_FOUND');
    }
  }

  async moveOrRenameFile(opts: {
    fileID: string;
    newName?: string;
    newParentID?: string;
  }): Promise<RemoteDriveFile> {
    const oldAbs = this.idToAbs(opts.fileID);
    const nextParentAbs = opts.newParentID ? this.idToAbs(opts.newParentID) : path.dirname(oldAbs);
    const nextName = opts.newName ?? path.basename(oldAbs);
    validateDriveName(nextName);
    await fsp.mkdir(nextParentAbs, { recursive: true });
    const nextAbs = path.join(nextParentAbs, nextName);
    if (path.resolve(oldAbs) !== path.resolve(nextAbs)) {
      await fsp.rename(oldAbs, nextAbs);
    }
    return this.statToRemote(nextAbs);
  }

  async deleteFile(fileID: string): Promise<void> {
    const abs = this.idToAbs(fileID);
    await fsp.rm(abs, { recursive: true, force: true }).catch(() => undefined);
  }
}
