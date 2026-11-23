import type { ISODateString, UUID } from './core.js';

export type AuthUserRole = 'owner' | 'admin' | 'member' | (string & {});

export type ApiTokenScope = 'read' | 'write' | 'sync' | 'mcp' | 'admin' | (string & {});

export interface AuthUser {
  id: UUID;
  username: string;
  displayName: string;
  role: AuthUserRole;
  createdAt: ISODateString;
  lastLoginAt?: ISODateString | null;
}

export interface AuthStatus {
  initialized: boolean;
  authenticated: boolean;
  user: AuthUser | null;
  sessionCount: number;
}

export interface AuthSessionInfo {
  id: UUID;
  userAgent?: string | null;
  ipAddress?: string | null;
  createdAt: ISODateString;
  lastSeenAt: ISODateString;
  expiresAt: ISODateString;
  isCurrent: boolean;
}

export interface ApiTokenInfo {
  id: UUID;
  name: string;
  prefix: string;
  scopes: ApiTokenScope[];
  createdAt: ISODateString;
  lastUsedAt?: ISODateString | null;
  expiresAt?: ISODateString | null;
}

export interface CreateApiTokenResult {
  /** Raw bearer secret returned exactly once on creation. */
  token: string;
  info: ApiTokenInfo;
}
