import crypto from 'node:crypto';
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

export const SESSION_COOKIE_NAME = 'charkle_session';
const DEFAULT_SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const REMEMBER_ME_SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const SCRYPT_KEYLEN = 64;
const SCRYPT_PARAMS: crypto.ScryptOptions = { N: 16384, r: 8, p: 1 };

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

function sha256Hex(input: string): string {
  return crypto.createHash('sha256').update(input, 'utf8').digest('hex');
}

function hashPassword(password: string): { hash: string; salt: string } {
  const salt = crypto.randomBytes(16).toString('hex');
  const derived = crypto.scryptSync(password, salt, SCRYPT_KEYLEN, SCRYPT_PARAMS);
  return { hash: derived.toString('hex'), salt };
}

function verifyPassword(password: string, expectedHashHex: string, salt: string): boolean {
  const derived = crypto.scryptSync(password, salt, SCRYPT_KEYLEN, SCRYPT_PARAMS);
  const expected = Buffer.from(expectedHashHex, 'hex');
  if (derived.length !== expected.length) return false;
  return crypto.timingSafeEqual(derived, expected);
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

export class AuthService implements IAuthService {
  public readonly sessionCookieName = SESSION_COOKIE_NAME;
  private readonly db: LibraryDatabase;

  constructor(db: LibraryDatabase) {
    this.db = db;
  }

  isInitialized(): boolean {
    const row = this.db.sqlite.prepare('SELECT COUNT(*) AS cnt FROM auth_users').get() as {
      cnt: number;
    };
    return Number(row?.cnt ?? 0) > 0;
  }

  bootstrapFromEnv(): AuthUser | null {
    if (this.isInitialized()) return null;
    const username = process.env.CHARKLE_ADMIN_USERNAME?.trim();
    const password = process.env.CHARKLE_ADMIN_PASSWORD;
    const displayName = process.env.CHARKLE_ADMIN_DISPLAY_NAME?.trim();
    if (!username || !password) return null;
    return this.setupAdmin(username, password, displayName || undefined);
  }

  setupAdmin(username: string, password: string, displayName?: string): AuthUser {
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

    return this.db.transaction(() => {
      if (this.isInitialized()) {
        throw new AuthError('管理员账号已初始化，请直接登录。', 409, 'ALREADY_INITIALIZED');
      }
      const { hash, salt } = hashPassword(password);
      const id = toSwiftUUID(crypto.randomUUID());
      const now = new Date().toISOString();
      const name = (displayName?.trim() || cleanUser).slice(0, 80);

      this.db.sqlite
        .prepare(
          `INSERT INTO auth_users (
            id, username, display_name, role, password_hash, password_salt, created_at, last_login_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)`,
        )
        .run(id, cleanUser, name, 'owner', hash, salt, now);

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

  login(
    username: string,
    password: string,
    opts: { rememberMe?: boolean; userAgent?: string | null; ipAddress?: string | null } = {},
  ): { user: AuthUser; rawSessionToken: string; expiresAt: string; sessionID: UUID } {
    const cleanUser = username.trim();
    const row = this.db.sqlite
      .prepare('SELECT * FROM auth_users WHERE username = ? COLLATE NOCASE')
      .get(cleanUser) as UserRow | undefined;

    if (!row || !verifyPassword(password, row.password_hash, row.password_salt)) {
      throw new AuthError('用户名或密码错误。', 401, 'INVALID_CREDENTIALS');
    }

    const now = new Date();
    const nowIso = now.toISOString();
    const ttlMs = opts.rememberMe ? REMEMBER_ME_SESSION_TTL_MS : DEFAULT_SESSION_TTL_MS;
    const expiresAt = new Date(now.getTime() + ttlMs).toISOString();

    const sessionID = toSwiftUUID(crypto.randomUUID());
    const rawSessionToken = crypto.randomBytes(32).toString('base64url');
    const tokenHash = sha256Hex(rawSessionToken);

    this.db.transaction(() => {
      this.db.sqlite
        .prepare('UPDATE auth_users SET last_login_at = ? WHERE id = ?')
        .run(nowIso, row.id);
      this.db.sqlite
        .prepare(
          `INSERT INTO auth_sessions (
            id, user_id, token_hash, user_agent, ip_address, created_at, last_seen_at, expires_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
          sessionID,
          row.id,
          tokenHash,
          opts.userAgent?.slice(0, 300) ?? null,
          opts.ipAddress?.slice(0, 128) ?? null,
          nowIso,
          nowIso,
          expiresAt,
        );
      // Prune expired sessions opportunistically
      this.db.sqlite
        .prepare('DELETE FROM auth_sessions WHERE expires_at <= ?')
        .run(nowIso);
    });

    const user: AuthUser = {
      ...rowToUser(row),
      lastLoginAt: nowIso,
    };
    return { user, rawSessionToken, expiresAt, sessionID };
  }

  verifySessionToken(rawToken: string): AuthenticatedPrincipal | null {
    if (!rawToken || rawToken.length < 16) return null;
    const hash = sha256Hex(rawToken);
    const session = this.db.sqlite
      .prepare('SELECT * FROM auth_sessions WHERE token_hash = ?')
      .get(hash) as SessionRow | undefined;
    if (!session) return null;

    const now = new Date();
    const nowIso = now.toISOString();
    if (Date.parse(session.expires_at) <= now.getTime()) {
      this.db.sqlite.prepare('DELETE FROM auth_sessions WHERE id = ?').run(session.id);
      return null;
    }

    const userRow = this.db.sqlite
      .prepare('SELECT * FROM auth_users WHERE id = ?')
      .get(session.user_id) as UserRow | undefined;
    if (!userRow) return null;

    // Throttle last_seen_at writes to once per 60 seconds
    if (now.getTime() - Date.parse(session.last_seen_at) > 60_000) {
      this.db.sqlite
        .prepare('UPDATE auth_sessions SET last_seen_at = ? WHERE id = ?')
        .run(nowIso, session.id);
    }

    return {
      user: rowToUser(userRow),
      authType: 'session',
      sessionID: session.id,
    };
  }

  verifyApiToken(rawToken: string): AuthenticatedPrincipal | null {
    if (!rawToken || !rawToken.startsWith('chk_') || rawToken.length < 20) return null;
    const hash = sha256Hex(rawToken);
    const tokenRow = this.db.sqlite
      .prepare('SELECT * FROM auth_tokens WHERE token_hash = ?')
      .get(hash) as TokenRow | undefined;
    if (!tokenRow) return null;

    const now = new Date();
    if (tokenRow.expires_at && Date.parse(tokenRow.expires_at) <= now.getTime()) {
      return null;
    }

    const userRow = this.db.sqlite
      .prepare('SELECT * FROM auth_users WHERE id = ?')
      .get(tokenRow.user_id) as UserRow | undefined;
    if (!userRow) return null;

    const nowIso = now.toISOString();
    this.db.sqlite
      .prepare('UPDATE auth_tokens SET last_used_at = ? WHERE id = ?')
      .run(nowIso, tokenRow.id);

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
    const row = this.db.sqlite
      .prepare('SELECT COUNT(*) AS cnt FROM auth_sessions WHERE user_id = ? AND expires_at > ?')
      .get(principal.user.id, nowIso) as { cnt: number };
    return {
      initialized,
      authenticated: true,
      user: principal.user,
      sessionCount: Number(row?.cnt ?? 0),
    };
  }

  logoutSession(sessionID: UUID): void {
    this.db.sqlite.prepare('DELETE FROM auth_sessions WHERE id = ?').run(toSwiftUUID(sessionID));
  }

  listSessions(userID: UUID, currentSessionID?: UUID): AuthSessionInfo[] {
    const nowIso = new Date().toISOString();
    const uid = toSwiftUUID(userID);
    const curID = currentSessionID ? toSwiftUUID(currentSessionID) : null;
    this.db.sqlite
      .prepare('DELETE FROM auth_sessions WHERE user_id = ? AND expires_at <= ?')
      .run(uid, nowIso);
    const rows = this.db.sqlite
      .prepare(
        'SELECT * FROM auth_sessions WHERE user_id = ? ORDER BY last_seen_at DESC, created_at DESC',
      )
      .all(uid) as unknown as SessionRow[];
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
    const res = this.db.sqlite
      .prepare('DELETE FROM auth_sessions WHERE id = ? AND user_id = ?')
      .run(toSwiftUUID(sessionID), toSwiftUUID(userID));
    return Number(res.changes) > 0;
  }

  revokeOtherSessions(userID: UUID, currentSessionID?: UUID): number {
    const uid = toSwiftUUID(userID);
    if (currentSessionID) {
      const res = this.db.sqlite
        .prepare('DELETE FROM auth_sessions WHERE user_id = ? AND id <> ?')
        .run(uid, toSwiftUUID(currentSessionID));
      return Number(res.changes);
    }
    const res = this.db.sqlite.prepare('DELETE FROM auth_sessions WHERE user_id = ?').run(uid);
    return Number(res.changes);
  }

  changePassword(
    userID: UUID,
    currentPassword: string,
    newPassword: string,
    currentSessionID?: UUID,
  ): void {
    if (newPassword.length < 8) {
      throw new AuthError('新密码长度至少需要 8 个字符。', 400, 'WEAK_PASSWORD');
    }
    const uid = toSwiftUUID(userID);
    const row = this.db.sqlite
      .prepare('SELECT * FROM auth_users WHERE id = ?')
      .get(uid) as UserRow | undefined;
    if (!row) {
      throw new AuthError('用户不存在。', 404, 'USER_NOT_FOUND');
    }
    if (!verifyPassword(currentPassword, row.password_hash, row.password_salt)) {
      throw new AuthError('当前密码不正确。', 401, 'INVALID_CREDENTIALS');
    }
    const { hash, salt } = hashPassword(newPassword);
    this.db.transaction(() => {
      this.db.sqlite
        .prepare('UPDATE auth_users SET password_hash = ?, password_salt = ? WHERE id = ?')
        .run(hash, salt, uid);
      this.revokeOtherSessions(uid, currentSessionID);
    });
  }

  listApiTokens(userID: UUID): ApiTokenInfo[] {
    const rows = this.db.sqlite
      .prepare('SELECT * FROM auth_tokens WHERE user_id = ? ORDER BY created_at DESC')
      .all(toSwiftUUID(userID)) as unknown as TokenRow[];
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
    const cleanScopes = scopes.length > 0 ? scopes : (['read', 'write', 'mcp'] as ApiTokenScope[]);
    const rawSecret = `chk_${crypto.randomBytes(32).toString('base64url')}`;
    const prefix = rawSecret.slice(0, 12);
    const tokenHash = sha256Hex(rawSecret);
    const id = toSwiftUUID(crypto.randomUUID());
    const now = new Date();
    const nowIso = now.toISOString();
    const expiresAt =
      expiresInDays && expiresInDays > 0
        ? new Date(now.getTime() + expiresInDays * 24 * 60 * 60 * 1000).toISOString()
        : null;

    this.db.sqlite
      .prepare(
        `INSERT INTO auth_tokens (
          id, user_id, name, prefix, token_hash, scopes, created_at, last_used_at, expires_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)`,
      )
      .run(
        id,
        toSwiftUUID(userID),
        cleanName.slice(0, 80),
        prefix,
        tokenHash,
        JSON.stringify(cleanScopes),
        nowIso,
        expiresAt,
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
    const res = this.db.sqlite
      .prepare('DELETE FROM auth_tokens WHERE id = ? AND user_id = ?')
      .run(toSwiftUUID(tokenID), toSwiftUUID(userID));
    return Number(res.changes) > 0;
  }
}
