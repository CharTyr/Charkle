import {
  toSwiftUUID,
  type ApiTokenInfo,
  type ApiTokenScope,
  type AuthSessionInfo,
  type AuthStatus,
  type AuthUser,
  type CreateApiTokenResult,
  type UUID,
} from '@charkle/shared';
import type { AuthenticatedPrincipal, IAuthService } from '../context.js';
import type { LibraryDatabase } from '../db/library-database.js';
import type { IPasswordHasher, RuntimeEnv } from '../runtime/types.js';
import { WebCryptoPasswordHasher } from '../runtime/web-crypto-hash.js';
import {
  bytesToBase64Url,
  randomBytes,
  randomUUID,
  readEnv,
  sha256HexSync,
} from '../runtime/web-crypto-utils.js';

export const SESSION_COOKIE_NAME = 'charkle_session';
const DEFAULT_SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const REMEMBER_ME_SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;

export class AuthError extends Error {
  public readonly statusCode: number;
  public readonly code: string;

  constructor(message: string, statusCode = 400, code = 'AUTH_ERROR') {
    super(message);
    this.name = 'AuthError';
    this.statusCode = statusCode;
    this.code = code;
  }
}

interface UserRow {
  id: string;
  username: string;
  display_name: string;
  role: string;
  password_hash: string;
  password_salt: string;
  created_at: string;
  last_login_at: string | null;
}

interface SessionRow {
  id: string;
  user_id: string;
  token_hash: string;
  user_agent: string | null;
  ip_address: string | null;
  created_at: string;
  last_seen_at: string;
  expires_at: string;
}

interface TokenRow {
  id: string;
  user_id: string;
  name: string;
  prefix: string;
  token_hash: string;
  scopes: string;
  created_at: string;
  last_used_at: string | null;
  expires_at: string | null;
}

function rowToUser(row: UserRow): AuthUser {
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name,
    role: row.role,
    createdAt: row.created_at,
    lastLoginAt: row.last_login_at,
  };
}

function validateUsernameAndPassword(username: string, password: string): string {
  const cleanUser = username.trim();
  if (cleanUser.length < 2) {
    throw new AuthError('用户名至少需要 2 个字符。', 400, 'INVALID_USERNAME');
  }
  if (cleanUser.length > 64 || !/^[a-zA-Z0-9._-]+$/.test(cleanUser)) {
    throw new AuthError('用户名仅支持字母、数字、点、下划线和连字符。', 400, 'INVALID_USERNAME');
  }
  if (password.length < 8) {
    throw new AuthError('密码长度至少需要 8 个字符。', 400, 'WEAK_PASSWORD');
  }
  return cleanUser;
}

export class AuthService implements IAuthService {
  public readonly sessionCookieName = SESSION_COOKIE_NAME;
  private readonly db: LibraryDatabase;
  private readonly hasher: IPasswordHasher;

  constructor(db: LibraryDatabase, hasher?: IPasswordHasher) {
    this.db = db;
    this.hasher = hasher ?? new WebCryptoPasswordHasher();
  }

  isInitialized(): boolean {
    const row = this.db.sql.get<{ cnt: number }>('SELECT COUNT(*) AS cnt FROM auth_users');
    return Number(row?.cnt ?? 0) > 0;
  }

  async bootstrapFromEnv(env?: RuntimeEnv): Promise<AuthUser | null> {
    if (this.isInitialized()) return null;
    const username = readEnv('CHARKLE_ADMIN_USERNAME', env)?.trim();
    const password = readEnv('CHARKLE_ADMIN_PASSWORD', env);
    const displayName = readEnv('CHARKLE_ADMIN_DISPLAY_NAME', env)?.trim();
    if (!username || !password) return null;
    return this.setupAdmin(username, password, displayName || undefined);
  }

  bootstrapFromEnvSync(env?: RuntimeEnv): AuthUser | null {
    if (this.isInitialized()) return null;
    const username = readEnv('CHARKLE_ADMIN_USERNAME', env)?.trim();
    const password = readEnv('CHARKLE_ADMIN_PASSWORD', env);
    const displayName = readEnv('CHARKLE_ADMIN_DISPLAY_NAME', env)?.trim();
    if (!username || !password) return null;
    if (!this.hasher.hashSync) {
      throw new AuthError('当前密码哈希实现不支持同步初始化，请调用异步 bootstrapFromEnv()。', 500);
    }
    const cleanUser = validateUsernameAndPassword(username, password);
    const encodedHash = this.hasher.hashSync(password);
    return this.insertAdminRecord(cleanUser, encodedHash, displayName || undefined);
  }

  private insertAdminRecord(
    cleanUser: string,
    encodedHash: string,
    displayName?: string,
  ): AuthUser {
    return this.db.transaction(() => {
      if (this.isInitialized()) {
        throw new AuthError('管理员账号已初始化，请直接登录。', 409, 'ALREADY_INITIALIZED');
      }
      const id = toSwiftUUID(randomUUID());
      const now = new Date().toISOString();
      const name = (displayName?.trim() || cleanUser).slice(0, 80);

      this.db.sql.run(
        `INSERT INTO auth_users (
          id, username, display_name, role, password_hash, password_salt, created_at, last_login_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)`,
        [id, cleanUser, name, 'owner', encodedHash, '', now],
      );

      return {
        id,
        username: cleanUser,
        displayName: name,
        role: 'owner',
        createdAt: now,
        lastLoginAt: null,
      };
    });
  }

  async setupAdmin(username: string, password: string, displayName?: string): Promise<AuthUser> {
    const cleanUser = validateUsernameAndPassword(username, password);
    if (this.isInitialized()) {
      throw new AuthError('管理员账号已初始化，请直接登录。', 409, 'ALREADY_INITIALIZED');
    }
    const encodedHash = await this.hasher.hash(password);
    return this.insertAdminRecord(cleanUser, encodedHash, displayName);
  }

  async login(
    username: string,
    password: string,
    opts: { rememberMe?: boolean; userAgent?: string | null; ipAddress?: string | null } = {},
  ): Promise<{ user: AuthUser; rawSessionToken: string; expiresAt: string; sessionID: UUID }> {
    const cleanUser = username.trim();
    const row = this.db.sql.get<UserRow>(
      'SELECT * FROM auth_users WHERE username = ? COLLATE NOCASE',
      [cleanUser],
    );

    const valid = row
      ? await this.hasher.verify(password, row.password_hash, row.password_salt)
      : false;
    if (!row || !valid) {
      throw new AuthError('用户名或密码错误。', 401, 'INVALID_CREDENTIALS');
    }

    const now = new Date();
    const nowIso = now.toISOString();
    const ttlMs = opts.rememberMe ? REMEMBER_ME_SESSION_TTL_MS : DEFAULT_SESSION_TTL_MS;
    const expiresAt = new Date(now.getTime() + ttlMs).toISOString();

    const sessionID = toSwiftUUID(randomUUID());
    const rawSessionToken = bytesToBase64Url(randomBytes(32));
    const tokenHash = sha256HexSync(rawSessionToken);

    this.db.transaction(() => {
      this.db.sql.run('UPDATE auth_users SET last_login_at = ? WHERE id = ?', [nowIso, row.id]);
      this.db.sql.run(
        `INSERT INTO auth_sessions (
          id, user_id, token_hash, user_agent, ip_address, created_at, last_seen_at, expires_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        [
          sessionID,
          row.id,
          tokenHash,
          opts.userAgent?.slice(0, 300) ?? null,
          opts.ipAddress?.slice(0, 128) ?? null,
          nowIso,
          nowIso,
          expiresAt,
        ],
      );
      this.db.sql.run('DELETE FROM auth_sessions WHERE expires_at <= ?', [nowIso]);
    });

    const user: AuthUser = {
      ...rowToUser(row),
      lastLoginAt: nowIso,
    };
    return { user, rawSessionToken, expiresAt, sessionID };
  }

  verifySessionToken(rawToken: string): AuthenticatedPrincipal | null {
    if (!rawToken || rawToken.length < 16) return null;
    const hash = sha256HexSync(rawToken);
    const session = this.db.sql.get<SessionRow>(
      'SELECT * FROM auth_sessions WHERE token_hash = ?',
      [hash],
    );
    if (!session) return null;

    const now = new Date();
    const nowIso = now.toISOString();
    if (Date.parse(session.expires_at) <= now.getTime()) {
      this.db.sql.run('DELETE FROM auth_sessions WHERE id = ?', [session.id]);
      return null;
    }

    const userRow = this.db.sql.get<UserRow>('SELECT * FROM auth_users WHERE id = ?', [
      session.user_id,
    ]);
    if (!userRow) return null;

    if (now.getTime() - Date.parse(session.last_seen_at) > 60_000) {
      this.db.sql.run('UPDATE auth_sessions SET last_seen_at = ? WHERE id = ?', [
        nowIso,
        session.id,
      ]);
    }

    return {
      user: rowToUser(userRow),
      authType: 'session',
      sessionID: session.id,
    };
  }

  verifyApiToken(rawToken: string): AuthenticatedPrincipal | null {
    if (!rawToken || !rawToken.startsWith('chk_') || rawToken.length < 20) return null;
    const hash = sha256HexSync(rawToken);
    const tokenRow = this.db.sql.get<TokenRow>(
      'SELECT * FROM auth_tokens WHERE token_hash = ?',
      [hash],
    );
    if (!tokenRow) return null;

    const now = new Date();
    if (tokenRow.expires_at && Date.parse(tokenRow.expires_at) <= now.getTime()) {
      return null;
    }

    const userRow = this.db.sql.get<UserRow>('SELECT * FROM auth_users WHERE id = ?', [
      tokenRow.user_id,
    ]);
    if (!userRow) return null;

    const nowIso = now.toISOString();
    this.db.sql.run('UPDATE auth_tokens SET last_used_at = ? WHERE id = ?', [
      nowIso,
      tokenRow.id,
    ]);

    let scopes: ApiTokenScope[] = ['read', 'write', 'mcp'];
    try {
      const parsed = JSON.parse(tokenRow.scopes);
      if (Array.isArray(parsed)) scopes = parsed.map(String);
    } catch {
      // Keep default scopes
    }

    return {
      user: rowToUser(userRow),
      authType: 'token',
      tokenID: tokenRow.id,
      scopes,
    };
  }

  getAuthStatus(principal: AuthenticatedPrincipal | null): AuthStatus {
    const initialized = this.isInitialized();
    if (!principal) {
      return {
        initialized,
        authenticated: false,
        user: null,
        sessionCount: 0,
      };
    }
    const nowIso = new Date().toISOString();
    const row = this.db.sql.get<{ cnt: number }>(
      'SELECT COUNT(*) AS cnt FROM auth_sessions WHERE user_id = ? AND expires_at > ?',
      [principal.user.id, nowIso],
    );
    return {
      initialized,
      authenticated: true,
      user: principal.user,
      sessionCount: Number(row?.cnt ?? 0),
    };
  }

  logoutSession(sessionID: UUID): void {
    this.db.sql.run('DELETE FROM auth_sessions WHERE id = ?', [toSwiftUUID(sessionID)]);
  }

  listSessions(userID: UUID, currentSessionID?: UUID): AuthSessionInfo[] {
    const nowIso = new Date().toISOString();
    const uid = toSwiftUUID(userID);
    const curID = currentSessionID ? toSwiftUUID(currentSessionID) : null;
    this.db.sql.run('DELETE FROM auth_sessions WHERE user_id = ? AND expires_at <= ?', [
      uid,
      nowIso,
    ]);
    const rows = this.db.sql.all<SessionRow>(
      'SELECT * FROM auth_sessions WHERE user_id = ? ORDER BY last_seen_at DESC, created_at DESC',
      [uid],
    );
    return rows.map((r) => ({
      id: r.id,
      userAgent: r.user_agent,
      ipAddress: r.ip_address,
      createdAt: r.created_at,
      lastSeenAt: r.last_seen_at,
      expiresAt: r.expires_at,
      isCurrent: curID !== null && r.id === curID,
    }));
  }

  revokeSession(userID: UUID, sessionID: UUID): boolean {
    const res = this.db.sql.run('DELETE FROM auth_sessions WHERE id = ? AND user_id = ?', [
      toSwiftUUID(sessionID),
      toSwiftUUID(userID),
    ]);
    return Number(res.changes) > 0;
  }

  revokeOtherSessions(userID: UUID, currentSessionID?: UUID): number {
    const uid = toSwiftUUID(userID);
    if (currentSessionID) {
      const res = this.db.sql.run('DELETE FROM auth_sessions WHERE user_id = ? AND id <> ?', [
        uid,
        toSwiftUUID(currentSessionID),
      ]);
      return Number(res.changes);
    }
    const res = this.db.sql.run('DELETE FROM auth_sessions WHERE user_id = ?', [uid]);
    return Number(res.changes);
  }

  async changePassword(
    userID: UUID,
    currentPassword: string,
    newPassword: string,
    currentSessionID?: UUID,
  ): Promise<void> {
    if (newPassword.length < 8) {
      throw new AuthError('新密码长度至少需要 8 个字符。', 400, 'WEAK_PASSWORD');
    }
    const uid = toSwiftUUID(userID);
    const row = this.db.sql.get<UserRow>('SELECT * FROM auth_users WHERE id = ?', [uid]);
    if (!row) {
      throw new AuthError('用户不存在。', 404, 'USER_NOT_FOUND');
    }
    const valid = await this.hasher.verify(currentPassword, row.password_hash, row.password_salt);
    if (!valid) {
      throw new AuthError('当前密码不正确。', 401, 'INVALID_CREDENTIALS');
    }
    const nextHash = await this.hasher.hash(newPassword);
    this.db.transaction(() => {
      this.db.sql.run(
        'UPDATE auth_users SET password_hash = ?, password_salt = ? WHERE id = ?',
        [nextHash, '', uid],
      );
      this.revokeOtherSessions(uid, currentSessionID);
    });
  }

  listApiTokens(userID: UUID): ApiTokenInfo[] {
    const rows = this.db.sql.all<TokenRow>(
      'SELECT * FROM auth_tokens WHERE user_id = ? ORDER BY created_at DESC',
      [toSwiftUUID(userID)],
    );
    return rows.map((r) => {
      let scopes: ApiTokenScope[] = [];
      try {
        const parsed = JSON.parse(r.scopes);
        if (Array.isArray(parsed)) scopes = parsed.map(String);
      } catch {
        scopes = [];
      }
      return {
        id: r.id,
        name: r.name,
        prefix: r.prefix,
        scopes,
        createdAt: r.created_at,
        lastUsedAt: r.last_used_at,
        expiresAt: r.expires_at,
      };
    });
  }

  createApiToken(
    userID: UUID,
    name: string,
    scopes: ApiTokenScope[],
    expiresInDays?: number | null,
  ): CreateApiTokenResult {
    const cleanName = name.trim();
    if (!cleanName) {
      throw new AuthError('访问令牌名称不能为空。', 400, 'INVALID_TOKEN_NAME');
    }
    const cleanScopes =
      scopes.length > 0 ? scopes : (['read', 'write', 'mcp'] as ApiTokenScope[]);
    const rawSecret = `chk_${bytesToBase64Url(randomBytes(32))}`;
    const prefix = rawSecret.slice(0, 12);
    const tokenHash = sha256HexSync(rawSecret);
    const id = toSwiftUUID(randomUUID());
    const now = new Date();
    const nowIso = now.toISOString();
    const expiresAt =
      expiresInDays && expiresInDays > 0
        ? new Date(now.getTime() + expiresInDays * 24 * 60 * 60 * 1000).toISOString()
        : null;

    this.db.sql.run(
      `INSERT INTO auth_tokens (
        id, user_id, name, prefix, token_hash, scopes, created_at, last_used_at, expires_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)`,
      [
        id,
        toSwiftUUID(userID),
        cleanName.slice(0, 80),
        prefix,
        tokenHash,
        JSON.stringify(cleanScopes),
        nowIso,
        expiresAt,
      ],
    );

    return {
      token: rawSecret,
      info: {
        id,
        name: cleanName.slice(0, 80),
        prefix,
        scopes: cleanScopes,
        createdAt: nowIso,
        lastUsedAt: null,
        expiresAt,
      },
    };
  }

  revokeApiToken(userID: UUID, tokenID: UUID): boolean {
    const res = this.db.sql.run('DELETE FROM auth_tokens WHERE id = ? AND user_id = ?', [
      toSwiftUUID(tokenID),
      toSwiftUUID(userID),
    ]);
    return Number(res.changes) > 0;
  }
}
