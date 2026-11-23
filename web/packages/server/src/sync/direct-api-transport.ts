import {
  GOOGLE_DRIVE_FOLDER_MIME_TYPE,
  type DriveAccountInfo,
  type DriveChange,
  type DriveChangePage,
  type RemoteDriveFile,
} from '@charkle/shared';
import {
  bytesToHex,
  concatBytes,
  randomBytes,
  toArrayBuffer,
  utf8Encode,
} from '../runtime/web-crypto-utils.js';
import {
  DriveTransportError,
  validateDriveName,
  type DriveDownloadStreamResult,
  type DriveTransport,
} from './drive-transport.js';
import type { GoogleOAuthClient } from './google-oauth.js';

const DRIVE_API_BASE = 'https://www.googleapis.com/drive/v3';
const DRIVE_UPLOAD_BASE = 'https://www.googleapis.com/upload/drive/v3';
const FILE_FIELDS = 'id,name,mimeType,size,modifiedTime,md5Checksum,parents,trashed,webViewLink,shortcutDetails';
const GOOGLE_DRIVE_SHORTCUT_MIME = 'application/vnd.google-apps.shortcut';
const MULTIPART_MAX_BYTES = 5 * 1024 * 1024; // Stream via resumable upload above 5 MiB

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
  shortcutDetails?: { targetId?: string; targetMimeType?: string };
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
 * Runtime-agnostic Google Drive API v3 transport supporting:
 * - My Drive + Shared Folders / Shared Drives (`supportsAllDrives=true&includeItemsFromAllDrives=true`)
 * - Streaming resumable uploads (`uploadType=resumable`) & streaming downloads (ZERO full-file buffering!)
 * - Incremental Changes feed
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

  private async fetchWithRetry(url: string, init: RequestInit & { duplex?: 'half' }): Promise<Response> {
    const canRetryBody =
      init.body === undefined ||
      typeof init.body === 'string' ||
      init.body instanceof ArrayBuffer ||
      init.body instanceof Uint8Array;
    const maxAttempts = canRetryBody ? 3 : 1;
    let lastRes: Response | null = null;
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      const res = await fetch(url, init);
      lastRes = res;
      if (res.status !== 429 && (res.status < 500 || res.status > 504)) {
        return res;
      }
      if (attempt + 1 < maxAttempts) {
        const retryAfter = Number.parseFloat(res.headers.get('retry-after') ?? '');
        const delayMs =
          Number.isFinite(retryAfter) && retryAfter > 0
            ? Math.min(5000, retryAfter * 1000)
            : Math.min(4000, 300 * Math.pow(2, attempt));
        await new Promise((r) => setTimeout(r, delayMs));
      }
    }
    return lastRes!;
  }

  async accountInfo(): Promise<DriveAccountInfo> {
    return this.oauth.fetchAccountInfo();
  }

  async resolveFolder(id: string): Promise<RemoteDriveFile> {
    const url = `${DRIVE_API_BASE}/files/${encodeURIComponent(id)}?supportsAllDrives=true&fields=${encodeURIComponent(FILE_FIELDS)}`;
    const res = await this.fetchWithRetry(url, { headers: await this.authHeaders() });
    if (!res.ok) {
      throw new DriveTransportError(
        `无法访问 Google Drive 目录 ${id}（HTTP ${res.status}）。`,
        'NOT_FOUND',
      );
    }
    let raw = (await res.json()) as RawDriveFile;
    if (raw.trashed) {
      throw new DriveTransportError(`Google Drive 目录 ${id} 已在回收站中。`, 'NOT_FOUND');
    }
    if (raw.mimeType === GOOGLE_DRIVE_SHORTCUT_MIME && raw.shortcutDetails?.targetId) {
      const targetUrl = `${DRIVE_API_BASE}/files/${encodeURIComponent(raw.shortcutDetails.targetId)}?supportsAllDrives=true&fields=${encodeURIComponent(FILE_FIELDS)}`;
      const targetRes = await this.fetchWithRetry(targetUrl, { headers: await this.authHeaders() });
      if (!targetRes.ok) {
        throw new DriveTransportError(
          `无法解析 Google Drive 目录快捷方式 ${id}（HTTP ${targetRes.status}）。`,
          'NOT_FOUND',
        );
      }
      raw = (await targetRes.json()) as RawDriveFile;
      if (raw.trashed) {
        throw new DriveTransportError(`快捷方式指向的目录 ${raw.id} 已在回收站中。`, 'NOT_FOUND');
      }
    }
    if (raw.mimeType !== GOOGLE_DRIVE_FOLDER_MIME_TYPE) {
      throw new DriveTransportError(`指定的 Drive ID (${id}) 不是文件夹。`, 'INVALID_FOLDER');
    }
    return mapDriveFile(raw);
  }

  async listSharedFolders(): Promise<RemoteDriveFile[]> {
    const q = `mimeType='${GOOGLE_DRIVE_FOLDER_MIME_TYPE}' and sharedWithMe=true and trashed=false`;
    const out: RemoteDriveFile[] = [];
    let pageToken: string | undefined;
    do {
      const params = new URLSearchParams({
        q,
        supportsAllDrives: 'true',
        includeItemsFromAllDrives: 'true',
        pageSize: '100',
        fields: `nextPageToken,files(${FILE_FIELDS})`,
      });
      if (pageToken) params.set('pageToken', pageToken);
      const res = await this.fetchWithRetry(`${DRIVE_API_BASE}/files?${params.toString()}`, {
        headers: await this.authHeaders(),
      });
      if (!res.ok) {
        throw new DriveTransportError(
          `无法获取共享文件夹列表（HTTP ${res.status}）。`,
          'API_ERROR',
        );
      }
      const json = (await res.json()) as { nextPageToken?: string; files?: RawDriveFile[] };
      for (const f of json.files ?? []) out.push(mapDriveFile(f));
      pageToken = json.nextPageToken;
    } while (pageToken);
    return out;
  }

  async findOrCreateFolder(name: string, parentID: string): Promise<RemoteDriveFile> {
    validateDriveName(name);
    const q = `name='${escapeDriveQueryLiteral(name)}' and '${escapeDriveQueryLiteral(parentID)}' in parents and mimeType='${GOOGLE_DRIVE_FOLDER_MIME_TYPE}' and trashed=false`;
    const params = new URLSearchParams({
      q,
      supportsAllDrives: 'true',
      includeItemsFromAllDrives: 'true',
      orderBy: 'createdTime',
      pageSize: '10',
      fields: `files(${FILE_FIELDS})`,
    });
    const findRes = await this.fetchWithRetry(`${DRIVE_API_BASE}/files?${params.toString()}`, {
      headers: await this.authHeaders(),
    });
    if (findRes.ok) {
      const json = (await findRes.json()) as { files?: RawDriveFile[] };
      if (json.files && json.files.length > 0) {
        return mapDriveFile(json.files[0]);
      }
    }

    const createRes = await this.fetchWithRetry(
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
      throw new DriveTransportError(
        `无法创建 Google Drive 目录 ${name}（HTTP ${createRes.status}）。`,
        'CREATE_FAILED',
      );
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
    data: Uint8Array | ReadableStream<Uint8Array>;
    size?: number;
    name: string;
    mimeType: string;
    parentID: string;
    existingFileID?: string | null;
  }): Promise<RemoteDriveFile> {
    validateDriveName(opts.name);
    const metadata: Record<string, unknown> = {
      name: opts.name,
      mimeType: opts.mimeType,
    };
    if (!opts.existingFileID) {
      metadata.parents = [opts.parentID];
    }

    // Small in-memory buffer -> fast single-request multipart/related upload
    if (opts.data instanceof Uint8Array && opts.data.byteLength <= MULTIPART_MAX_BYTES) {
      const boundary = `charkle_${bytesToHex(randomBytes(12))}`;
      const head = utf8Encode(
        `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(metadata)}\r\n--${boundary}\r\nContent-Type: ${opts.mimeType || 'application/octet-stream'}\r\n\r\n`,
      );
      const tail = utf8Encode(`\r\n--${boundary}--`);
      const body = concatBytes([head, opts.data, tail]);

      const url = opts.existingFileID
        ? `${DRIVE_UPLOAD_BASE}/files/${encodeURIComponent(opts.existingFileID)}?uploadType=multipart&supportsAllDrives=true&fields=${encodeURIComponent(FILE_FIELDS)}`
        : `${DRIVE_UPLOAD_BASE}/files?uploadType=multipart&supportsAllDrives=true&fields=${encodeURIComponent(FILE_FIELDS)}`;

      const res = await fetch(url, {
        method: opts.existingFileID ? 'PATCH' : 'POST',
        headers: await this.authHeaders({
          'Content-Type': `multipart/related; boundary=${boundary}`,
        }),
        body: toArrayBuffer(body),
      });
      if (!res.ok) {
        throw new DriveTransportError(
          `上传文件到 Google Drive 失败（HTTP ${res.status}）。`,
          'UPLOAD_FAILED',
        );
      }
      return mapDriveFile((await res.json()) as RawDriveFile);
    }

    // Streaming or large payload -> Google Drive resumable upload (zero 128 MB buffering!)
    const contentLength =
      opts.data instanceof Uint8Array ? opts.data.byteLength : opts.size;
    const initUrl = opts.existingFileID
      ? `${DRIVE_UPLOAD_BASE}/files/${encodeURIComponent(opts.existingFileID)}?uploadType=resumable&supportsAllDrives=true&fields=${encodeURIComponent(FILE_FIELDS)}`
      : `${DRIVE_UPLOAD_BASE}/files?uploadType=resumable&supportsAllDrives=true&fields=${encodeURIComponent(FILE_FIELDS)}`;

    const initHeaders: Record<string, string> = {
      'Content-Type': 'application/json; charset=UTF-8',
      'X-Upload-Content-Type': opts.mimeType || 'application/octet-stream',
    };
    if (contentLength !== undefined && Number.isFinite(contentLength)) {
      initHeaders['X-Upload-Content-Length'] = String(contentLength);
    }

    const initRes = await fetch(initUrl, {
      method: opts.existingFileID ? 'PATCH' : 'POST',
      headers: await this.authHeaders(initHeaders),
      body: JSON.stringify(metadata),
    });
    if (!initRes.ok) {
      throw new DriveTransportError(
        `初始化 Google Drive 流式上传失败（HTTP ${initRes.status}）。`,
        'UPLOAD_FAILED',
      );
    }
    const uploadUri = initRes.headers.get('location');
    if (!uploadUri) {
      throw new DriveTransportError('Google Drive 未返回上传会话地址。', 'UPLOAD_FAILED');
    }

    const putHeaders: Record<string, string> = {
      'Content-Type': opts.mimeType || 'application/octet-stream',
    };
    if (contentLength !== undefined && Number.isFinite(contentLength)) {
      putHeaders['Content-Length'] = String(contentLength);
    }

    const putInit: RequestInit & { duplex?: 'half' } = {
      method: 'PUT',
      headers: putHeaders,
      body: opts.data instanceof Uint8Array ? toArrayBuffer(opts.data) : opts.data,
      ...(opts.data instanceof Uint8Array ? {} : { duplex: 'half' }),
    };

    const putRes = await fetch(uploadUri, putInit);
    if (!putRes.ok) {
      throw new DriveTransportError(
        `流式上传文件到 Google Drive 失败（HTTP ${putRes.status}）。`,
        'UPLOAD_FAILED',
      );
    }
    return mapDriveFile((await putRes.json()) as RawDriveFile);
  }

  async downloadFileStream(fileID: string): Promise<DriveDownloadStreamResult> {
    const url = `${DRIVE_API_BASE}/files/${encodeURIComponent(fileID)}?alt=media&supportsAllDrives=true`;
    const res = await fetch(url, { headers: await this.authHeaders() });
    if (!res.ok) {
      throw new DriveTransportError(
        `从 Google Drive 下载失败（HTTP ${res.status}）。`,
        'DOWNLOAD_FAILED',
      );
    }
    const sizeHeader = res.headers.get('content-length');
    const size = sizeHeader ? Number.parseInt(sizeHeader, 10) : null;
    const stream =
      res.body ??
      new ReadableStream<Uint8Array>({
        async start(controller) {
          const bytes = new Uint8Array(await res.arrayBuffer());
          if (bytes.byteLength > 0) controller.enqueue(bytes);
          controller.close();
        },
      });
    return {
      stream,
      size: Number.isFinite(size) ? size : null,
      contentType: res.headers.get('content-type'),
    };
  }

  async downloadFile(fileID: string): Promise<Uint8Array> {
    const url = `${DRIVE_API_BASE}/files/${encodeURIComponent(fileID)}?alt=media&supportsAllDrives=true`;
    const res = await fetch(url, { headers: await this.authHeaders() });
    if (!res.ok) {
      throw new DriveTransportError(
        `从 Google Drive 下载失败（HTTP ${res.status}）。`,
        'DOWNLOAD_FAILED',
      );
    }
    return new Uint8Array(await res.arrayBuffer());
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

    // Resolve current parents when moving so Google Drive API v3 always receives paired
    // `addParents` + `removeParents` (and skips parent mutation on same-folder rename, `P0-14`).
    if (opts.newParentID) {
      let removeList: string[] = [];
      if (opts.previousParentID) {
        if (opts.previousParentID !== opts.newParentID) {
          removeList = [opts.previousParentID];
        }
      } else {
        const metaRes = await this.fetchWithRetry(
          `${DRIVE_API_BASE}/files/${encodeURIComponent(opts.fileID)}?supportsAllDrives=true&fields=parents`,
          { headers: await this.authHeaders() },
        );
        if (metaRes.ok) {
          const metaJson = (await metaRes.json()) as { parents?: string[] };
          const currentParents = Array.isArray(metaJson.parents) ? metaJson.parents : [];
          if (!currentParents.includes(opts.newParentID)) {
            removeList = currentParents;
          } else {
            // Already in target parent — same-folder rename only!
            removeList = [];
          }
          if (!currentParents.includes(opts.newParentID)) {
            params.set('addParents', opts.newParentID);
            if (removeList.length > 0) {
              params.set('removeParents', removeList.join(','));
            }
          }
        } else {
          params.set('addParents', opts.newParentID);
        }
      }
      if (opts.previousParentID && opts.previousParentID !== opts.newParentID) {
        params.set('addParents', opts.newParentID);
        params.set('removeParents', opts.previousParentID);
      }
    }

    const payload: Record<string, unknown> = {};
    if (opts.newName) {
      validateDriveName(opts.newName);
      payload.name = opts.newName;
    }
    const res = await this.fetchWithRetry(
      `${DRIVE_API_BASE}/files/${encodeURIComponent(opts.fileID)}?${params.toString()}`,
      {
        method: 'PATCH',
        headers: await this.authHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify(payload),
      },
    );
    if (!res.ok) {
      throw new DriveTransportError(
        `移动/重命名 Drive 文件失败（HTTP ${res.status}）。`,
        'MOVE_FAILED',
      );
    }
    return mapDriveFile((await res.json()) as RawDriveFile);
  }

  async deleteFile(fileID: string): Promise<void> {
    const url = `${DRIVE_API_BASE}/files/${encodeURIComponent(fileID)}?supportsAllDrives=true`;
    const res = await this.fetchWithRetry(url, {
      method: 'PATCH',
      headers: await this.authHeaders({ 'Content-Type': 'application/json' }),
      body: JSON.stringify({ trashed: true }),
    });
    if (!res.ok && res.status !== 404) {
      throw new DriveTransportError(
        `删除 Drive 文件失败（HTTP ${res.status}）。`,
        'DELETE_FAILED',
      );
    }
  }

  async getStartPageToken(): Promise<string> {
    const res = await this.fetchWithRetry(
      `${DRIVE_API_BASE}/changes/startPageToken?supportsAllDrives=true`,
      { headers: await this.authHeaders() },
    );
    if (!res.ok) {
      throw new DriveTransportError(
        `获取 Drive Changes token 失败（HTTP ${res.status}）。`,
        'API_ERROR',
      );
    }
    const json = (await res.json()) as { startPageToken: string };
    return json.startPageToken;
  }

  async listChanges(pageToken: string): Promise<DriveChangePage> {
    const params = new URLSearchParams({
      pageToken,
      supportsAllDrives: 'true',
      includeItemsFromAllDrives: 'true',
      includeRemoved: 'true',
      spaces: 'drive',
      pageSize: '500',
      fields: `nextPageToken,newStartPageToken,changes(fileId,removed,file(${FILE_FIELDS}))`,
    });
    const res = await this.fetchWithRetry(`${DRIVE_API_BASE}/changes?${params.toString()}`, {
      headers: await this.authHeaders(),
    });
    if (!res.ok) {
      throw new DriveTransportError(
        `获取 Drive 增量变更失败（HTTP ${res.status}）。`,
        'API_ERROR',
      );
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
