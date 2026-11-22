import type {
  DriveAccountInfo,
  DriveChangePage,
  RemoteDriveFile,
} from '@charkle/shared';

export const DRIVE_ROOT_ID = 'root';

export class DriveTransportError extends Error {
  public readonly code: string;

  constructor(message: string, code = 'DRIVE_ERROR') {
    super(message);
    this.name = 'DriveTransportError';
    this.code = code;
  }
}

export function validateDriveName(name: string): void {
  if (
    !name ||
    name === '.' ||
    name === '..' ||
    name.includes('/') ||
    /[\x00-\x1f]/.test(name)
  ) {
    throw new DriveTransportError(`Invalid remote file name: "${name}"`, 'INVALID_NAME');
  }
}

/**
 * Backend-agnostic remote storage transport implemented by Google Drive API v3,
 * WebDAV, Local Folder / gdirect mount, and InMemory test transport.
 */
export interface DriveTransport {
  readonly displayName: string;
  readonly supportsChangesAPI: boolean;

  accountInfo(): Promise<DriveAccountInfo>;
  resolveFolder(id: string): Promise<RemoteDriveFile>;
  findOrCreateFolder(name: string, parentID: string): Promise<RemoteDriveFile>;
  listFiles(parentID: string): Promise<RemoteDriveFile[]>;
  uploadFile(opts: {
    data: Buffer;
    name: string;
    mimeType: string;
    parentID: string;
    existingFileID?: string | null;
  }): Promise<RemoteDriveFile>;
  downloadFile(fileID: string): Promise<Buffer>;
  moveOrRenameFile(opts: {
    fileID: string;
    newName?: string;
    newParentID?: string;
    previousParentID?: string;
  }): Promise<RemoteDriveFile>;
  deleteFile(fileID: string): Promise<void>;

  getStartPageToken?(): Promise<string>;
  listChanges?(pageToken: string): Promise<DriveChangePage>;
  listSharedFolders?(): Promise<RemoteDriveFile[]>;
}
