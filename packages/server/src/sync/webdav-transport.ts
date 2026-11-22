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

export interface WebDAVTransportOptions {
  serverURL: string;
  username: string;
  password: string;
}

function joinDavPath(base: string, ...parts: string[]): string {
  const segs: string[] = [];
  for (const part of [base, ...parts]) {
    for (const s of part.split('/')) {
      if (s && s !== '.' && s !== '..') segs.push(s);
    }
  }
  return '/' + segs.join('/');
}

function encodeDavPath(davPath: string): string {
  return (
    '/' +
    davPath
      .split('/')
      .filter(Boolean)
      .map((seg) => encodeURIComponent(seg))
      .join('/')
  );
}

function decodeXmlTag(block: string, tagName: string): string | null {
  const re = new RegExp(`<(?:[a-zA-Z0-9_-]+:)?${tagName}[^>]*>([\\s\\S]*?)<\\/(?:[a-zA-Z0-9_-]+:)?${tagName}>`, 'i');
  const m = re.exec(block);
  if (!m) return null;
  return m[1]
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .trim();
}

/**
 * Full WebDAV transport implementing PROPFIND, GET, PUT, MKCOL, MOVE, DELETE with Basic Auth.
 */
export class WebDAVTransport implements DriveTransport {
  public readonly displayName = 'WebDAV';
  public readonly supportsChangesAPI = false;
  private readonly baseOrigin: string;
  private readonly basePath: string;
  private readonly authHeader: string;
  private readonly username: string;

  constructor(opts: WebDAVTransportOptions) {
    const trimmed = opts.serverURL.trim();
    if (!trimmed) {
      throw new DriveTransportError('请先填写 WebDAV 服务器地址。', 'NOT_CONFIGURED');
    }
    const parsed = new URL(trimmed);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      throw new DriveTransportError('WebDAV 地址必须以 http:// 或 https:// 开头。', 'INVALID_URL');
    }
    this.baseOrigin = parsed.origin;
    this.basePath = parsed.pathname.replace(/\/+$/, '');
    this.username = opts.username.trim();
    const token = Buffer.from(`${this.username}:${opts.password ?? ''}`, 'utf8').toString('base64');
    this.authHeader = `Basic ${token}`;
  }

  private fullURL(id: string, trailingSlash = false): string {
    const rel = id === DRIVE_ROOT_ID ? '' : id;
    const combined = joinDavPath(this.basePath, rel);
    const encoded = encodeDavPath(combined);
    const suffix = trailingSlash && !encoded.endsWith('/') ? '/' : '';
    return `${this.baseOrigin}${encoded}${suffix}`;
  }

  private async request(
    method: string,
    id: string,
    opts: {
      headers?: Record<string, string>;
      body?: Buffer | string;
      trailingSlash?: boolean;
    } = {},
  ): Promise<Response> {
    const url = this.fullURL(id, opts.trailingSlash);
    const res = await fetch(url, {
      method,
      headers: {
        Authorization: this.authHeader,
        'User-Agent': 'CharkleWeb/1.0',
        ...(opts.headers ?? {}),
      },
      body: opts.body ? (typeof opts.body === 'string' ? opts.body : new Uint8Array(opts.body)) : undefined,
    });
    return res;
  }

  async accountInfo(): Promise<DriveAccountInfo> {
    const res = await this.request('PROPFIND', DRIVE_ROOT_ID, {
      headers: { Depth: '0', 'Content-Type': 'application/xml; charset=utf-8' },
      trailingSlash: true,
    });
    if (res.status === 401 || res.status === 403) {
      throw new DriveTransportError('WebDAV 认证失败，请检查用户名与密码。', 'UNAUTHORIZED');
    }
    if (!res.ok && res.status !== 207) {
      throw new DriveTransportError(`WebDAV 连接失败（HTTP ${res.status}）。`, 'NETWORK_ERROR');
    }
    const host = new URL(this.baseOrigin).hostname;
    return {
      email: this.username ? `${this.username}@${host}` : host,
      displayName: `WebDAV (${host})`,
      storageUsedBytes: null,
      storageLimitBytes: null,
      source: 'webdav',
    };
  }

  async resolveFolder(id: string): Promise<RemoteDriveFile> {
    const res = await this.request('PROPFIND', id, {
      headers: { Depth: '0' },
      trailingSlash: true,
    });
    if (!res.ok && res.status !== 207) {
      throw new DriveTransportError(`WebDAV 目录不存在：${id}`, 'NOT_FOUND');
    }
    const clean = id === DRIVE_ROOT_ID ? '' : id.replace(/^\/+|\/+$/g, '');
    const parts = clean.split('/').filter(Boolean);
    return {
      id: clean || DRIVE_ROOT_ID,
      name: parts[parts.length - 1] ?? 'WebDAV',
      mimeType: GOOGLE_DRIVE_FOLDER_MIME_TYPE,
      size: 0,
      modifiedTime: new Date().toISOString(),
      md5Checksum: null,
      parents: parts.length > 1 ? [parts.slice(0, -1).join('/')] : [DRIVE_ROOT_ID],
      trashed: false,
      webViewLink: null,
    };
  }

  async findOrCreateFolder(name: string, parentID: string): Promise<RemoteDriveFile> {
    validateDriveName(name);
    const childID = parentID === DRIVE_ROOT_ID ? name : `${parentID}/${name}`;
    const mk = await this.request('MKCOL', childID, { trailingSlash: true });
    // 201 Created, 405 Method Not Allowed (already exists), 301/200 OK
    if (!mk.ok && mk.status !== 405 && mk.status !== 301) {
      throw new DriveTransportError(`无法创建 WebDAV 目录 ${childID}（HTTP ${mk.status}）。`, 'MKCOL_FAILED');
    }
    return {
      id: childID,
      name,
      mimeType: GOOGLE_DRIVE_FOLDER_MIME_TYPE,
      size: 0,
      modifiedTime: new Date().toISOString(),
      md5Checksum: null,
      parents: [parentID],
      trashed: false,
      webViewLink: null,
    };
  }

  async listFiles(parentID: string): Promise<RemoteDriveFile[]> {
    const res = await this.request('PROPFIND', parentID, {
      headers: { Depth: '1', 'Content-Type': 'application/xml; charset=utf-8' },
      body: `<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/><d:getcontenttype/></d:prop></d:propfind>`,
      trailingSlash: true,
    });
    if (res.status === 404) return [];
    if (!res.ok && res.status !== 207) {
      throw new DriveTransportError(`WebDAV 目录列表失败（HTTP ${res.status}）。`, 'PROPFIND_FAILED');
    }
    const xml = await res.text();
    const responses = xml.match(/<(?:[a-zA-Z0-9_-]+:)?response[\s\S]*?<\/(?:[a-zA-Z0-9_-]+:)?response>/gi) ?? [];
    const expectedParentPath = joinDavPath(this.basePath, parentID === DRIVE_ROOT_ID ? '' : parentID).replace(/\/+$/, '');
    const items: RemoteDriveFile[] = [];

    for (const block of responses) {
      const rawHref = decodeXmlTag(block, 'href');
      if (!rawHref) continue;
      let hrefPath: string;
      try {
        hrefPath = rawHref.startsWith('http') ? new URL(rawHref).pathname : rawHref;
      } catch {
        hrefPath = rawHref;
      }
      const decodedPath = decodeURIComponent(hrefPath).replace(/\/+$/, '');
      if (decodedPath === expectedParentPath) continue; // skip self

      const relFromBase =
        this.basePath && decodedPath.startsWith(this.basePath)
          ? decodedPath.slice(this.basePath.length).replace(/^\/+/, '')
          : decodedPath.replace(/^\/+/, '');
      if (!relFromBase) continue;

      const name = relFromBase.split('/').pop() ?? relFromBase;
      if (name === '.DS_Store' || name.startsWith('._')) continue;

      const isCollection = /<(?:[a-zA-Z0-9_-]+:)?collection\s*\/?>/i.test(block);
      const sizeStr = decodeXmlTag(block, 'getcontentlength');
      const modifiedStr = decodeXmlTag(block, 'getlastmodified');
      const etag = decodeXmlTag(block, 'getetag')?.replace(/^W\//, '').replace(/"/g, '') ?? null;
      const contentType = decodeXmlTag(block, 'getcontenttype');

      let modifiedIso: string | null = null;
      if (modifiedStr) {
        const ms = Date.parse(modifiedStr);
        if (Number.isFinite(ms)) modifiedIso = new Date(ms).toISOString();
      }

      items.push({
        id: relFromBase,
        name,
        mimeType: isCollection
          ? GOOGLE_DRIVE_FOLDER_MIME_TYPE
          : contentType || guessMimeType(name),
        size: sizeStr ? Number.parseInt(sizeStr, 10) || 0 : 0,
        modifiedTime: modifiedIso,
        md5Checksum: etag,
        parents: [parentID],
        trashed: false,
        webViewLink: null,
      });
    }
    return items;
  }

  async uploadFile(opts: {
    data: Buffer;
    name: string;
    mimeType: string;
    parentID: string;
    existingFileID?: string | null;
  }): Promise<RemoteDriveFile> {
    validateDriveName(opts.name);
    const id = opts.parentID === DRIVE_ROOT_ID ? opts.name : `${opts.parentID}/${opts.name}`;
    const res = await this.request('PUT', id, {
      headers: { 'Content-Type': opts.mimeType || 'application/octet-stream' },
      body: opts.data,
    });
    if (!res.ok) {
      throw new DriveTransportError(`WebDAV 上传失败 ${id}（HTTP ${res.status}）。`, 'PUT_FAILED');
    }
    if (opts.existingFileID && opts.existingFileID !== id) {
      await this.deleteFile(opts.existingFileID).catch(() => undefined);
    }
    return {
      id,
      name: opts.name,
      mimeType: opts.mimeType,
      size: opts.data.length,
      modifiedTime: new Date().toISOString(),
      md5Checksum: null,
      parents: [opts.parentID],
      trashed: false,
      webViewLink: null,
    };
  }

  async downloadFile(fileID: string): Promise<Buffer> {
    const res = await this.request('GET', fileID);
    if (!res.ok) {
      throw new DriveTransportError(`WebDAV 下载失败 ${fileID}（HTTP ${res.status}）。`, 'GET_FAILED');
    }
    return Buffer.from(await res.arrayBuffer());
  }

  async moveOrRenameFile(opts: {
    fileID: string;
    newName?: string;
    newParentID?: string;
  }): Promise<RemoteDriveFile> {
    const parts = opts.fileID.split('/');
    const oldName = parts.pop() ?? opts.fileID;
    const oldParent = parts.join('/') || DRIVE_ROOT_ID;
    const nextName = opts.newName ?? oldName;
    const nextParent = opts.newParentID ?? oldParent;
    validateDriveName(nextName);
    const nextID = nextParent === DRIVE_ROOT_ID ? nextName : `${nextParent}/${nextName}`;

    if (nextID !== opts.fileID) {
      const destURL = this.fullURL(nextID);
      const res = await this.request('MOVE', opts.fileID, {
        headers: { Destination: destURL, Overwrite: 'T' },
      });
      if (!res.ok) {
        throw new DriveTransportError(`WebDAV 移动/重命名失败（HTTP ${res.status}）。`, 'MOVE_FAILED');
      }
    }
    return {
      id: nextID,
      name: nextName,
      mimeType: guessMimeType(nextName),
      size: null,
      modifiedTime: new Date().toISOString(),
      md5Checksum: null,
      parents: [nextParent],
      trashed: false,
      webViewLink: null,
    };
  }

  async deleteFile(fileID: string): Promise<void> {
    const res = await this.request('DELETE', fileID);
    if (!res.ok && res.status !== 404) {
      throw new DriveTransportError(`WebDAV 删除失败（HTTP ${res.status}）。`, 'DELETE_FAILED');
    }
  }
}
