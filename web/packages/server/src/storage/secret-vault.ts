import type { ISqlDatabase, RuntimeEnv } from '../runtime/types.js';
import {
  base64ToBytes,
  bytesToBase64,
  bytesToHex,
  concatBytes,
  hexToBytes,
  randomBytes,
  readEnv,
  sha256BytesSync,
  toArrayBuffer,
  utf8Decode,
  utf8Encode,
} from '../runtime/web-crypto-utils.js';

export const SECRET_KEYS = {
  GEMINI_API_KEY: 'ai.gemini.apiKey',
  OPENAI_API_KEY: 'ai.openAICompatible.apiKey',
  CHATGPT_ACCESS_TOKEN: 'ai.chatGPT.accessToken',
  CHATGPT_REFRESH_TOKEN: 'ai.chatGPT.refreshToken',
  TYPESAFE_API_KEY: 'ai.typesafe.apiKey',
  GOOGLE_OAUTH_CLIENT_ID: 'sync.google.clientId',
  GOOGLE_OAUTH_CLIENT_SECRET: 'sync.google.clientSecret',
  GOOGLE_OAUTH_TOKENS: 'sync.google.tokens',
  WEBDAV_PASSWORD: 'sync.webdav.password',
} as const;

export const VAULT_SECRETS_STATE_KEY = 'vault.secrets.v1';
const VAULT_MASTER_KEY_STATE_KEY = 'vault.master_key.v1';

export interface EncryptedVaultPayload {
  version: 1;
  iv: string;
  ciphertext: string;
  /** Optional legacy separate GCM tag (from pre-SQLite Node file format); Web Crypto embeds tag in ciphertext. */
  tag?: string;
}

export interface SyncVaultCryptoAdapter {
  encrypt(keyBytes: Uint8Array, plaintext: string): EncryptedVaultPayload;
  decrypt(keyBytes: Uint8Array, payload: EncryptedVaultPayload): string | null;
}

export interface SecretVaultOptions {
  /** Explicit passphrase/secret (falls back to `CHARKLE_VAULT_KEY`, `CHARKLE_VAULT_SECRET`, or persisted SQL key). */
  masterKeySecret?: string;
  /** Optional raw 32-byte key override (e.g., when migrating legacy Node `.vault-key`). */
  rawMasterKeyBytes?: Uint8Array;
  env?: RuntimeEnv;
  /** Optional Node-only synchronous AES-256-GCM adapter sharing the exact same wire format as Web Crypto. */
  syncCrypto?: SyncVaultCryptoAdapter;
}

/**
 * Runtime-agnostic AES-256-GCM encrypted key-value vault persisted in `ISqlDatabase`
 * under `sync_state['vault.secrets.v1']`.
 *
 * Uses Web Crypto `crypto.subtle` AES-256-GCM natively on Cloudflare Workers and Node 26.
 * Call `await SecretVault.open(sql, options)` (or `await vault.ready()`) on startup so
 * persisted entries are decrypted before serving requests, and `await vault.flush()` after
 * mutations (automatically handled by `core-app.ts` middleware).
 */
export class SecretVault {
  private readonly sql: ISqlDatabase;
  private readonly masterKeyBytes: Uint8Array;
  private readonly syncCrypto?: SyncVaultCryptoAdapter;
  private entries: Record<string, string> = {};
  private cryptoKeyPromise: Promise<CryptoKey> | null = null;
  private initialized = false;
  private initPromise: Promise<void> | null = null;
  private writeChain: Promise<void> = Promise.resolve();

  constructor(sql: ISqlDatabase, options: SecretVaultOptions = {}) {
    this.sql = sql;
    this.syncCrypto = options.syncCrypto;
    this.sql.exec('CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, payload TEXT NOT NULL);');
    this.masterKeyBytes = this.resolveMasterKey(options);

    // If a synchronous crypto adapter is provided (Node), load immediately so sync callers see existing secrets
    if (this.syncCrypto) {
      this.loadSync();
      this.initialized = true;
    }
  }

  static async open(sql: ISqlDatabase, options: SecretVaultOptions = {}): Promise<SecretVault> {
    const vault = new SecretVault(sql, options);
    await vault.ready();
    return vault;
  }

  private resolveMasterKey(options: SecretVaultOptions): Uint8Array {
    if (options.rawMasterKeyBytes && options.rawMasterKeyBytes.byteLength === 32) {
      return new Uint8Array(options.rawMasterKeyBytes);
    }
    const envSecret =
      options.masterKeySecret?.trim() ||
      readEnv('CHARKLE_VAULT_KEY', options.env)?.trim() ||
      readEnv('CHARKLE_VAULT_SECRET', options.env)?.trim();
    if (envSecret && envSecret.length > 0) {
      return sha256BytesSync(envSecret);
    }

    const row = this.sql.get<{ payload: string }>(
      'SELECT payload FROM sync_state WHERE key = ?',
      [VAULT_MASTER_KEY_STATE_KEY],
    );
    if (row) {
      try {
        const hex = JSON.parse(row.payload) as string;
        if (typeof hex === 'string' && hex.length === 64) {
          const decoded = hexToBytes(hex);
          if (decoded.byteLength === 32) return decoded;
        }
      } catch {
        // Regenerate if malformed
      }
    }

    const generated = randomBytes(32);
    this.sql.run(
      'INSERT OR REPLACE INTO sync_state (key, payload) VALUES (?, ?)',
      [VAULT_MASTER_KEY_STATE_KEY, JSON.stringify(bytesToHex(generated))],
    );
    return generated;
  }

  private getWebCryptoKey(): Promise<CryptoKey> {
    if (!this.cryptoKeyPromise) {
      this.cryptoKeyPromise = globalThis.crypto.subtle.importKey(
        'raw',
        toArrayBuffer(this.masterKeyBytes),
        { name: 'AES-GCM' },
        false,
        ['encrypt', 'decrypt'],
      );
    }
    return this.cryptoKeyPromise;
  }

  private readEncryptedPayload(): EncryptedVaultPayload | null {
    const row = this.sql.get<{ payload: string }>(
      'SELECT payload FROM sync_state WHERE key = ?',
      [VAULT_SECRETS_STATE_KEY],
    );
    if (!row) return null;
    try {
      const parsed = JSON.parse(row.payload) as EncryptedVaultPayload;
      if (parsed && parsed.version === 1 && parsed.iv && parsed.ciphertext) {
        return parsed;
      }
    } catch {
      // Ignore corrupted payload
    }
    return null;
  }

  private writeEncryptedPayload(payload: EncryptedVaultPayload): void {
    this.sql.run(
      'INSERT OR REPLACE INTO sync_state (key, payload) VALUES (?, ?)',
      [VAULT_SECRETS_STATE_KEY, JSON.stringify(payload)],
    );
  }

  private loadSync(): void {
    if (!this.syncCrypto) return;
    const payload = this.readEncryptedPayload();
    if (!payload) return;
    const plain = this.syncCrypto.decrypt(this.masterKeyBytes, payload);
    if (!plain) return;
    try {
      const parsed = JSON.parse(plain) as Record<string, string>;
      if (parsed && typeof parsed === 'object') {
        this.entries = { ...parsed, ...this.entries };
      }
    } catch {
      // Recover cleanly
    }
  }

  async ready(): Promise<void> {
    if (this.initialized) return;
    if (!this.initPromise) {
      this.initPromise = (async () => {
        const payload = this.readEncryptedPayload();
        if (payload) {
          try {
            const key = await this.getWebCryptoKey();
            const iv = base64ToBytes(payload.iv);
            const rawCt = base64ToBytes(payload.ciphertext);
            const combined = payload.tag
              ? concatBytes([rawCt, base64ToBytes(payload.tag)])
              : rawCt;
            const plainBuf = await globalThis.crypto.subtle.decrypt(
              { name: 'AES-GCM', iv: toArrayBuffer(iv) },
              key,
              toArrayBuffer(combined),
            );
            const parsed = JSON.parse(utf8Decode(new Uint8Array(plainBuf))) as Record<string, string>;
            if (parsed && typeof parsed === 'object') {
              // Preserve any in-memory writes made before ready() completed
              this.entries = { ...parsed, ...this.entries };
            }
          } catch {
            // If key changed or payload is unreadable, keep clean state
          }
        }
        this.initialized = true;
      })();
    }
    await this.initPromise;
  }

  private schedulePersist(): void {
    if (this.syncCrypto) {
      const payload = this.syncCrypto.encrypt(this.masterKeyBytes, JSON.stringify(this.entries));
      this.writeEncryptedPayload(payload);
      return;
    }

    const snapshot = JSON.stringify(this.entries);
    this.writeChain = this.writeChain
      .catch(() => undefined)
      .then(async () => {
        const key = await this.getWebCryptoKey();
        const iv = randomBytes(12);
        const encrypted = await globalThis.crypto.subtle.encrypt(
          { name: 'AES-GCM', iv: toArrayBuffer(iv) },
          key,
          toArrayBuffer(utf8Encode(snapshot)),
        );
        const payload: EncryptedVaultPayload = {
          version: 1,
          iv: bytesToBase64(iv),
          ciphertext: bytesToBase64(new Uint8Array(encrypted)),
        };
        this.writeEncryptedPayload(payload);
      });
  }

  async flush(): Promise<void> {
    await this.writeChain;
  }

  /**
   * Imports legacy secret entries (e.g. from pre-SQLite `<dataDir>/vault.enc.json`)
   * without overwriting keys already present in SQLite.
   */
  importEntriesIfMissing(legacyEntries: Record<string, string>): void {
    let changed = false;
    for (const [k, v] of Object.entries(legacyEntries)) {
      if (typeof v === 'string' && v.length > 0 && !this.entries[k]) {
        this.entries[k] = v;
        changed = true;
      }
    }
    if (changed) {
      this.schedulePersist();
    }
  }

  get(key: string): string | null {
    const val = this.entries[key];
    return typeof val === 'string' && val.length > 0 ? val : null;
  }

  set(key: string, value: string): void {
    if (!value) {
      this.delete(key);
      return;
    }
    this.entries[key] = value;
    this.schedulePersist();
  }

  async setAsync(key: string, value: string): Promise<void> {
    await this.ready();
    this.set(key, value);
    await this.flush();
  }

  delete(key: string): void {
    if (key in this.entries) {
      delete this.entries[key];
      this.schedulePersist();
    }
  }

  async deleteAsync(key: string): Promise<void> {
    await this.ready();
    this.delete(key);
    await this.flush();
  }

  has(key: string): boolean {
    return typeof this.entries[key] === 'string' && this.entries[key].length > 0;
  }

  keys(): string[] {
    return Object.keys(this.entries);
  }
}
