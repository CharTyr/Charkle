import type { DriveAccountInfo } from '@charkle/shared';
import type { RuntimeEnv } from '../runtime/types.js';
import {
  bytesToBase64Url,
  randomBytes,
  readEnv,
  sha256BytesSync,
} from '../runtime/web-crypto-utils.js';
import { SECRET_KEYS, type SecretVault } from '../storage/secret-vault.js';
import { DriveTransportError } from './drive-transport.js';

export interface GoogleOAuthTokens {
  accessToken: string;
  refreshToken?: string | null;
  expiresAtMs: number;
  scope?: string;
}

interface PendingPkceState {
  codeVerifier: string;
  redirectUri: string;
  createdAtMs: number;
}

export interface OAuthStateStoreLike {
  getState<T>(key: string): T | null;
  setState<T>(key: string, value: T | null): void;
}

const GOOGLE_AUTH_ENDPOINT = 'https://accounts.google.com/o/oauth2/v2/auth';
const GOOGLE_TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token';
const GOOGLE_DRIVE_SCOPE = 'https://www.googleapis.com/auth/drive';
const PKCE_STATE_PREFIX = 'oauth.google.pkce.';
const PKCE_TTL_MS = 15 * 60 * 1000;

/**
 * Runtime-agnostic PKCE OAuth 2.0 client for Google Drive API v3 storing credentials,
 * refresh tokens inside `SecretVault`, and PKCE state durably inside SQLite (survives DO eviction!).
 */
export class GoogleOAuthClient {
  private readonly vault: SecretVault;
  private readonly stateStore?: OAuthStateStoreLike;
  private readonly env?: RuntimeEnv;
  private readonly pendingStates = new Map<string, PendingPkceState>();

  constructor(vault: SecretVault, options: { stateStore?: OAuthStateStoreLike; env?: RuntimeEnv } = {}) {
    this.vault = vault;
    this.stateStore = options.stateStore;
    this.env = options.env;
  }

  hasClientConfig(): boolean {
    return Boolean(this.getClientCredentials());
  }

  getClientCredentials(): { clientID: string; clientSecret: string } | null {
    const clientID =
      this.vault.get(SECRET_KEYS.GOOGLE_OAUTH_CLIENT_ID) ??
      readEnv('CHARKLE_GOOGLE_CLIENT_ID', this.env)?.trim() ??
      null;
    const clientSecret =
      this.vault.get(SECRET_KEYS.GOOGLE_OAUTH_CLIENT_SECRET) ??
      readEnv('CHARKLE_GOOGLE_CLIENT_SECRET', this.env)?.trim() ??
      '';
    if (!clientID) return null;
    return { clientID, clientSecret };
  }

  saveClientCredentials(clientID: string, clientSecret: string): void {
    const cleanID = clientID.trim();
    if (!cleanID) {
      throw new DriveTransportError('Google OAuth Client ID 不能为空。', 'INVALID_CONFIG');
    }
    this.vault.set(SECRET_KEYS.GOOGLE_OAUTH_CLIENT_ID, cleanID);
    if (clientSecret.trim()) {
      this.vault.set(SECRET_KEYS.GOOGLE_OAUTH_CLIENT_SECRET, clientSecret.trim());
    }
  }

  loadTokens(): GoogleOAuthTokens | null {
    const raw = this.vault.get(SECRET_KEYS.GOOGLE_OAUTH_TOKENS);
    if (!raw) return null;
    try {
      const parsed = JSON.parse(raw) as GoogleOAuthTokens;
      return parsed?.accessToken ? parsed : null;
    } catch {
      return null;
    }
  }

  private saveTokens(tokens: GoogleOAuthTokens): void {
    this.vault.set(SECRET_KEYS.GOOGLE_OAUTH_TOKENS, JSON.stringify(tokens));
  }

  clearTokens(): void {
    this.vault.delete(SECRET_KEYS.GOOGLE_OAUTH_TOKENS);
  }

  startAuthorization(redirectUri: string): { authURL: string; state: string } {
    const creds = this.getClientCredentials();
    if (!creds) {
      throw new DriveTransportError(
        '尚未配置 Google OAuth Client ID，请先在设置中保存 OAuth 凭据。',
        'NOT_CONFIGURED',
      );
    }

    const now = Date.now();
    for (const [k, v] of this.pendingStates.entries()) {
      if (now - v.createdAtMs > PKCE_TTL_MS) this.pendingStates.delete(k);
    }

    const state = bytesToBase64Url(randomBytes(24));
    const codeVerifier = bytesToBase64Url(randomBytes(32));
    const codeChallenge = bytesToBase64Url(sha256BytesSync(codeVerifier));

    const entry: PendingPkceState = { codeVerifier, redirectUri, createdAtMs: now };
    this.pendingStates.set(state, entry);
    this.stateStore?.setState(`${PKCE_STATE_PREFIX}${state}`, entry);

    const params = new URLSearchParams({
      client_id: creds.clientID,
      redirect_uri: redirectUri,
      response_type: 'code',
      scope: GOOGLE_DRIVE_SCOPE,
      access_type: 'offline',
      prompt: 'consent',
      state,
      code_challenge: codeChallenge,
      code_challenge_method: 'S256',
    });

    return {
      authURL: `${GOOGLE_AUTH_ENDPOINT}?${params.toString()}`,
      state,
    };
  }

  async exchangeCode(
    code: string,
    state: string,
    redirectUri?: string,
  ): Promise<DriveAccountInfo> {
    const creds = this.getClientCredentials();
    if (!creds) {
      throw new DriveTransportError('未配置 Google OAuth 凭据。', 'NOT_CONFIGURED');
    }
    const persistedKey = `${PKCE_STATE_PREFIX}${state}`;
    const pending =
      this.pendingStates.get(state) ??
      this.stateStore?.getState<PendingPkceState>(persistedKey) ??
      null;
    this.pendingStates.delete(state);
    this.stateStore?.setState(persistedKey, null);

    if (!pending || Date.now() - pending.createdAtMs > PKCE_TTL_MS) {
      throw new DriveTransportError('OAuth state 无效或已过期，请重新发起授权。', 'INVALID_STATE');
    }

    const body = new URLSearchParams({
      code,
      client_id: creds.clientID,
      redirect_uri: redirectUri || pending.redirectUri,
      grant_type: 'authorization_code',
      code_verifier: pending.codeVerifier,
    });
    if (creds.clientSecret) {
      body.set('client_secret', creds.clientSecret);
    }

    const res = await fetch(GOOGLE_TOKEN_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new DriveTransportError(
        `Google OAuth 换取令牌失败（HTTP ${res.status}）：${text.slice(0, 200)}`,
        'OAUTH_EXCHANGE_FAILED',
      );
    }
    const json = (await res.json()) as {
      access_token: string;
      refresh_token?: string;
      expires_in?: number;
      scope?: string;
    };
    const existing = this.loadTokens();
    const tokens: GoogleOAuthTokens = {
      accessToken: json.access_token,
      refreshToken: json.refresh_token ?? existing?.refreshToken ?? null,
      expiresAtMs: Date.now() + Math.max(60, (json.expires_in ?? 3600) - 60) * 1000,
      scope: json.scope,
    };
    this.saveTokens(tokens);

    return this.fetchAccountInfo(tokens.accessToken);
  }

  async getValidAccessToken(): Promise<string> {
    const tokens = this.loadTokens();
    if (!tokens) {
      throw new DriveTransportError('尚未登录 Google Drive 账号。', 'UNAUTHORIZED');
    }
    if (Date.now() < tokens.expiresAtMs) {
      return tokens.accessToken;
    }
    if (!tokens.refreshToken) {
      throw new DriveTransportError('Google Drive 登录已过期，请重新授权。', 'UNAUTHORIZED');
    }

    const creds = this.getClientCredentials();
    if (!creds) {
      throw new DriveTransportError('缺少 Google OAuth Client ID，无法刷新令牌。', 'NOT_CONFIGURED');
    }
    const body = new URLSearchParams({
      client_id: creds.clientID,
      refresh_token: tokens.refreshToken,
      grant_type: 'refresh_token',
    });
    if (creds.clientSecret) body.set('client_secret', creds.clientSecret);

    const res = await fetch(GOOGLE_TOKEN_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });
    if (!res.ok) {
      throw new DriveTransportError('刷新 Google Drive 访问令牌失败，请重新登录。', 'UNAUTHORIZED');
    }
    const json = (await res.json()) as { access_token: string; expires_in?: number };
    const refreshed: GoogleOAuthTokens = {
      ...tokens,
      accessToken: json.access_token,
      expiresAtMs: Date.now() + Math.max(60, (json.expires_in ?? 3600) - 60) * 1000,
    };
    this.saveTokens(refreshed);
    return refreshed.accessToken;
  }

  async fetchAccountInfo(accessToken?: string): Promise<DriveAccountInfo> {
    const token = accessToken ?? (await this.getValidAccessToken());
    const res = await fetch(
      'https://www.googleapis.com/drive/v3/about?fields=user(emailAddress,displayName),storageQuota(usage,limit)',
      { headers: { Authorization: `Bearer ${token}` } },
    );
    if (!res.ok) {
      throw new DriveTransportError(
        `无法读取 Google Drive 账号信息（HTTP ${res.status}）。`,
        'API_ERROR',
      );
    }
    const json = (await res.json()) as {
      user?: { emailAddress?: string; displayName?: string };
      storageQuota?: { usage?: string; limit?: string };
    };
    return {
      email: json.user?.emailAddress ?? 'google-drive',
      displayName: json.user?.displayName ?? null,
      storageUsedBytes: json.storageQuota?.usage ? Number(json.storageQuota.usage) : null,
      storageLimitBytes: json.storageQuota?.limit ? Number(json.storageQuota.limit) : null,
      source: 'googleDrive',
    };
  }
}
