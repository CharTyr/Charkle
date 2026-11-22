import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

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

interface EncryptedVaultPayload {
  version: 1;
  iv: string;
  tag: string;
  ciphertext: string;
}

/**
 * AES-256-GCM encrypted key-value vault persisted at `<dataDir>/vault.enc.json`.
 * Uses `CHARKLE_VAULT_SECRET` when configured, otherwise auto-generates and stores
 * a 32-byte key file `<dataDir>/.vault-key` with `0o600` permissions.
 */
export class SecretVault {
  private readonly dataDir: string;
  private readonly vaultPath: string;
  private readonly keyPath: string;
  private readonly masterKey: Buffer;
  private entries: Record<string, string>;

  constructor(dataDir: string, explicitSecret?: string) {
    this.dataDir = dataDir;
    fs.mkdirSync(dataDir, { recursive: true });
    this.vaultPath = path.join(dataDir, 'vault.enc.json');
    this.keyPath = path.join(dataDir, '.vault-key');
    this.masterKey = this.resolveMasterKey(explicitSecret ?? process.env.CHARKLE_VAULT_SECRET);
    this.entries = this.load();
  }

  private resolveMasterKey(envSecret?: string): Buffer {
    if (envSecret && envSecret.trim().length > 0) {
      return crypto.createHash('sha256').update(envSecret.trim(), 'utf8').digest();
    }
    try {
      if (fs.existsSync(this.keyPath)) {
        const hex = fs.readFileSync(this.keyPath, 'utf8').trim();
        const buf = Buffer.from(hex, 'hex');
        if (buf.length === 32) return buf;
      }
    } catch {
      // Regenerate below if unreadable
    }
    const generated = crypto.randomBytes(32);
    fs.writeFileSync(this.keyPath, generated.toString('hex') + '\n', { mode: 0o600 });
    return generated;
  }

  private load(): Record<string, string> {
    if (!fs.existsSync(this.vaultPath)) return {};
    try {
      const raw = fs.readFileSync(this.vaultPath, 'utf8');
      const payload = JSON.parse(raw) as EncryptedVaultPayload;
      if (payload.version !== 1 || !payload.iv || !payload.tag || !payload.ciphertext) {
        return {};
      }
      const decipher = crypto.createDecipheriv(
        'aes-256-gcm',
        this.masterKey,
        Buffer.from(payload.iv, 'base64'),
      );
      decipher.setAuthTag(Buffer.from(payload.tag, 'base64'));
      const plain = Buffer.concat([
        decipher.update(Buffer.from(payload.ciphertext, 'base64')),
        decipher.final(),
      ]).toString('utf8');
      const parsed = JSON.parse(plain) as Record<string, string>;
      return parsed && typeof parsed === 'object' ? parsed : {};
    } catch {
      return {};
    }
  }

  private persist(): void {
    fs.mkdirSync(this.dataDir, { recursive: true });
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', this.masterKey, iv);
    const plain = JSON.stringify(this.entries);
    const encrypted = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();
    const payload: EncryptedVaultPayload = {
      version: 1,
      iv: iv.toString('base64'),
      tag: tag.toString('base64'),
      ciphertext: encrypted.toString('base64'),
    };
    const tmpPath = `${this.vaultPath}.${process.pid}.${Date.now()}.tmp`;
    fs.writeFileSync(tmpPath, JSON.stringify(payload, null, 2) + '\n', { mode: 0o600 });
    fs.renameSync(tmpPath, this.vaultPath);
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
    this.persist();
  }

  delete(key: string): void {
    if (key in this.entries) {
      delete this.entries[key];
      this.persist();
    }
  }

  has(key: string): boolean {
    return typeof this.entries[key] === 'string' && this.entries[key].length > 0;
  }

  keys(): string[] {
    return Object.keys(this.entries);
  }
}
