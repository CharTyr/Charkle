import crypto from 'node:crypto';
import {
  GOOGLE_DRIVE_FOLDER_MIME_TYPE,
  type DriveAccountInfo,
  type DriveChange,
  type DriveChangePage,
  type RemoteDriveFile,
} from '@charkle/shared';
import {
  DriveTransportError,
  validateDriveName,
  type DriveTransport,
} from './drive-transport.js';
import type { GoogleOAuthClient } from './google-oauth.js';

const DRIVE_API_BASE = 'https://www.googleapis.com/drive/v3';
const DRIVE_UPLOAD_BASE = 'https://www.googleapis.com/upload/drive/v3';
const FILE_FIELDS = 'id,name,mimeType,size,modifiedTime,md5Checksum,parents,trashed,webViewLink';

interface RawDriveFile {
  id: string;
  name: string;
  mimeType: string;
  size?: string;
  modifiedTime?: string;
  md5Checksum?: string;
  parents?: string[];
  trashed?: boolean;
  webViewLink?: string;
}

function mapDriveFile(raw: RawDriveFile): RemoteDriveFile {
  return {
    id: raw.id,
    name: raw.name,
    mimeType: raw.mimeType,
    size: raw.size !== undefined ? Number(raw.size) : null,
    modifiedTime: raw.modifiedTime ?? null,
    md5Checksum: raw.md5Checksum ?? null,
    parents: Array.isArray(raw.parents) ? raw.parents : [],
    trashed: Boolean(raw.trashed),
    webViewLink: raw.webViewLink ?? null,
  };
}

function escapeDriveQueryLiteral(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
}

/**
 * Google Drive API v3 transport supporting My Drive + Shared Folders/Shared Drives
 * (`supportsAllDrives=true&includeItemsFromAllDrives=true`) and incremental Changes feed.
 */
export class DirectAPITransport implements DriveTransport {
  public readonly displayName = 'Google Drive API v3';
  public readonly supportsChangesAPI = true;
  private readonly oauth: GoogleOAuthClient;

  constructor(oauth: GoogleOAuthClient) {
    this.oauth = oauth;
  }

  private async authHeaders(extra: Record<string, string> = {}): Promise<Record<string, string>> {
    const token = await this.oauth.getValidAccessToken();
    return {
      Authorization: `Bearer ${token}`,
      ...extra,
    };
  }

  async accountInfo(): Promise<DriveAccountInfo> {
    return this.oauth.fetchAccountInfo();
  }

  async resolveFolder(id: string): Promise<RemoteDriveFile> {
    const url = `${DRIVE_API_BASE}/files/${encodeURIComponent(id)}?supportsAllDrives=true&fields=${encodeURIComponent(FILE_FIELDS)}`;
    const res = await fetch(url, { headers: await this.authHeaders() });
    if (!res.ok) {
      throw new DriveTransportError(`无法访问 Google Drive 目录 ${id}（HTTP ${res.status}）。`, 'NOT_FOUND');
    }
    const raw = (await res.json()) as RawDriveFile;
    if (raw.mimeType !== GOOGLE_DRIVE_FOLDER_MIME_TYPE) {
      throw new DriveTransportError(`指定的 Drive ID (${id}) 不是文件夹。`, 'INVALID_FOLDER');
    }
    return mapDriveFile(raw);
  }

  async listSharedFolders(): Promise<RemoteDriveFile[]> {
    const q = `mimeType='${GOOGLE_DRIVE_FOLDER_MIME_TYPE}' and sharedWithMe=true and trashed=false`;
    const params = new URLSearchParams({
      q,
      supportsAllDrives: 'true',
      includeItemsFromAllDrives: 'true',
      pageSize: '100',
      fields: `files(${FILE_FIELDS})`,
    });
    const res = await fetch(`${DRIVE_API_BASE}/files?${params.toString()}`, {
      headers: await this.authHeaders(),
    });
    if (!res.ok) {
      throw new DriveTransportError(`无法获取共享文件夹列表（HTTP ${res.status}）。`, 'API_ERROR');
    }
    const json = (await res.json()) as { files?: RawDriveFile[] };
    return (json.files ?? []).map(mapDriveFile);
  }

  async findOrCreateFolder(name: string, parentID: string): Promise<RemoteDriveFile> {
    validateDriveName(name);
    const q = `name='${escapeDriveQueryLiteral(name)}' and '${escapeDriveQueryLiteral(parentID)}' in parents and mimeType='${GOOGLE_DRIVE_FOLDER_MIME_TYPE}' and trashed=false`;
    const params = new URLSearchParams({
      q,
      supportsAllDrives: 'true',
      includeItemsFromAllDrives: 'true',
      pageSize: '10',
      fields: `files(${FILE_FIELDS})`,
    });
    const findRes = await fetch(`${DRIVE_API_BASE}/files?${params.toString()}`, {
      headers: await this.authHeaders(),
    });
    if (findRes.ok) {
      const json = (await findRes.json()) as { files?: RawDriveFile[] };
      if (json.files && json.files.length > 0) {
        return mapDriveFile(json.files[0]);
      }
    }

    const createRes = await fetch(
      `${DRIVE_API_BASE}/files?supportsAllDrives=true&fields=${encodeURIComponent(FILE_FIELDS)}`,
      {
        method: 'POST',
        headers: await this.authHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify({
          name,
          mimeType: GOOGLE_DRIVE_FOLDER_MIME_TYPE,
          parents: [parentID],
        }),
      },
    );
    if (!createRes.ok) {
      throw new DriveTransportError(`无法创建 Google Drive 目录 ${name}（HTTP ${createRes.status}）。`, 'CREATE_FAILED');
    }
    return mapDriveFile((await createRes.json()) as RawDriveFile);
  }

  async listFiles(parentID: string): Promise<RemoteDriveFile[]> {
    const out: RemoteDriveFile[] = [];
    let pageToken: string | undefined;
    do {
      const params = new URLSearchParams({
        q: `'${escapeDriveQueryLiteral(parentID)}' in parents and trashed=false`,
        supportsAllDrives: 'true',
        includeItemsFromAllDrives: 'true',
        pageSize: '1000',
        fields: `nextPageToken,files(${FILE_FIELDS})`,
      });
      if (pageToken) params.set('pageToken', pageToken);
      const res = await fetch(`${DRIVE_API_BASE}/files?${params.toString()}`, {
        headers: await this.authHeaders(),
      });
      if (!res.ok) {
        throw new DriveTransportError(`列出 Drive 文件失败（HTTP ${res.status}）。`, 'LIST_FAILED');
      }
      const json = (await res.json()) as { nextPageToken?: string; files?: RawDriveFile[] };
      for (const f of json.files ?? []) out.push(mapDriveFile(f));
      pageToken = json.nextPageToken;
    } while (pageToken);
    return out;
  }

  async uploadFile(opts: {
    data: Buffer;
    name: string;
    mimeType: string;
    parentID: string;
    existingFileID?: string | null;
  }): Promise<RemoteDriveFile> {
    validateDriveName(opts.name);
    const boundary = `charkle_${crypto.randomBytes(12).toString('hex')}`;
    const metadata: Record<string, unknown> = {
      name: opts.name,
      mimeType: opts.mimeType,
    };
    if (!opts.existingFileID) {
      metadata.parents = [opts.parentID];
    }

    const head = Buffer.from(
      `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n--${boundary}\r\nContent-Type: ${opts.mimeType || 'application/octet-stream'}\r\n\r\n`,
      'utf8',
    );
    const tail = Buffer.from(`\r\n--${boundary}--`, 'utf8');
    const body = Buffer.concat([head, opts.data, tail]);

    const url = opts.existingFileID
      ? `${DRIVE_UPLOAD_BASE}/files/${encodeURIComponent(opts.existingFileID)}?uploadType=multipart&supportsAllDrives=true&fields=${encodeURIComponent(FILE_FIELDS)}`
      : `${DRIVE_UPLOAD_BASE}/files?uploadType=multipart&supportsAllDrives=true&fields=${encodeURIComponent(FILE_FIELDS)}`;

    const res = await fetch(url, {
      method: opts.existingFileID ? 'PATCH' : 'POST',
      headers: await this.authHeaders({
        'Content-Type': `multipart/related; boundary=${boundary}`,
      }),
      body: new Uint8Array(body),
    });
    if (!res.ok) {
      throw new DriveTransportError(`上传文件到 Google Drive 失败（HTTP ${res.status}）。`, 'UPLOAD_FAILED');
    }
    return mapDriveFile((await res.json()) as RawDriveFile);
  }

  async downloadFile(fileID: string): Promise<Buffer> {
    const url = `${DRIVE_API_BASE}/files/${encodeURIComponent(fileID)}?alt=media&supportsAllDrives=true`;
    const res = await fetch(url, { headers: await this.authHeaders() });
    if (!res.ok) {
      throw new DriveTransportError(`从 Google Drive 下载失败（HTTP ${res.status}）。`, 'DOWNLOAD_FAILED');
    }
    return Buffer.from(await res.arrayBuffer());
  }

  async moveOrRenameFile(opts: {
    fileID: string;
    newName?: string;
    newParentID?: string;
    previousParentID?: string;
  }): Promise<RemoteDriveFile> {
    const params = new URLSearchParams({
      supportsAllDrives: 'true',
      fields: FILE_FIELDS,
    });
    if (opts.newParentID) params.set('addParents', opts.newParentID);
    if (opts.previousParentID) params.set('removeParents', opts.previousParentID);
    const payload: Record<string, unknown> = {};
    if (opts.newName) {
      validateDriveName(opts.newName);
      payload.name = opts.newName;
    }
    const res = await fetch(`${DRIVE_API_BASE}/files/${encodeURIComponent(opts.fileID)}?${params.toString()}`, {
      method: 'PATCH',
      headers: await this.authHeaders({ 'Content-Type': 'application/json' }),
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      throw new DriveTransportError(`移动/重命名 Drive 文件失败（HTTP ${res.status}）。`, 'MOVE_FAILED');
    }
    return mapDriveFile((await res.json()) as RawDriveFile);
  }

  async deleteFile(fileID: string): Promise<void> {
    const url = `${DRIVE_API_BASE}/files/${encodeURIComponent(fileID)}?supportsAllDrives=true`;
    const res = await fetch(url, {
      method: 'PATCH',
      headers: await this.authHeaders({ 'Content-Type': 'application/json' }),
      body: JSON.stringify({ trashed: true }),
    });
    if (!res.ok && res.status !== 404) {
      throw new DriveTransportError(`删除 Drive 文件失败（HTTP ${res.status}）。`, 'DELETE_FAILED');
    }
  }

  async getStartPageToken(): Promise<string> {
    const res = await fetch(`${DRIVE_API_BASE}/changes/startPageToken?supportsAllDrives=true`, {
      headers: await this.authHeaders(),
    });
    if (!res.ok) {
      throw new DriveTransportError(`获取 Drive Changes token 失败（HTTP ${res.status}）。`, 'API_ERROR');
    }
    const json = (await res.json()) as { startPageToken: string };
    return json.startPageToken;
  }

  async listChanges(pageToken: string): Promise<DriveChangePage> {
    const params = new URLSearchParams({
      pageToken,
      supportsAllDrives: 'true',
      includeItemsFromAllDrives: 'true',
      pageSize: '500',
      fields: `nextPageToken,newStartPageToken,changes(fileId,removed,file(${FILE_FIELDS}))`,
    });
    const res = await fetch(`${DRIVE_API_BASE}/changes?${params.toString()}`, {
      headers: await this.authHeaders(),
    });
    if (!res.ok) {
      throw new DriveTransportError(`获取 Drive 增量变更失败（HTTP ${res.status}）。`, 'API_ERROR');
    }
    const json = (await res.json()) as {
      nextPageToken?: string;
      newStartPageToken?: string;
      changes?: Array<{ fileId: string; removed?: boolean; file?: RawDriveFile }>;
    };
    const changes: DriveChange[] = (json.changes ?? []).map((c) => ({
      fileID: c.fileId,
      removed: Boolean(c.removed),
      file: c.file ? mapDriveFile(c.file) : null,
    }));
    return {
      changes,
      nextPageToken: json.nextPageToken ?? null,
      newStartPageToken: json.newStartPageToken ?? null,
    };
  }
}
