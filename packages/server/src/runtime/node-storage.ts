import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { ConfigStore, type PersistedConfigSnapshot } from '../storage/config-store.js';
import {
  SecretVault,
  type EncryptedVaultPayload,
  type SyncVaultCryptoAdapter,
} from '../storage/secret-vault.js';
import type { ISqlDatabase } from './types.js';

/**
 * Node.js synchronous AES-256-GCM adapter whose wire payload (`iv` + `ciphertext||tag`)
 * is 100% bit-for-bit interoperable with Web Crypto `crypto.subtle` AES-256-GCM.
 */
export const nodeSyncVaultCrypto: SyncVaultCryptoAdapter = {
  encrypt(keyBytes: Uint8Array, plaintext: string): EncryptedVaultPayload {
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', keyBytes, iv);
    const encrypted = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();
    const combined = Buffer.concat([encrypted, tag]);
    return {
      version: 1,
      iv: iv.toString('base64'),
      ciphertext: combined.toString('base64'),
    };
  },

  decrypt(keyBytes: Uint8Array, payload: EncryptedVaultPayload): string | null {
    try {
      const iv = Buffer.from(payload.iv, 'base64');
      let ct: Buffer;
      let tag: Buffer;
      if (payload.tag) {
        ct = Buffer.from(payload.ciphertext, 'base64');
        tag = Buffer.from(payload.tag, 'base64');
      } else {
        const combined = Buffer.from(payload.ciphertext, 'base64');
        if (combined.length < 16) return null;
        tag = combined.subarray(combined.length - 16);
        ct = combined.subarray(0, combined.length - 16);
      }
      const decipher = crypto.createDecipheriv('aes-256-gcm', keyBytes, iv);
      decipher.setAuthTag(tag);
      return Buffer.concat([decipher.update(ct), decipher.final()]).toString('utf8');
    } catch {
      return null;
    }
  },
};

/**
 * Creates a SQLite-backed `ConfigStore` for Node.js, automatically migrating any legacy
 * `<dataDir>/config.json` file into SQLite on first launch.
 */
export function createNodeConfigStore(sql: ISqlDatabase, dataDir: string): ConfigStore {
  const store = new ConfigStore(sql, {
    defaultLocalLibraryPath: path.join(dataDir, 'library'),
  });
  const legacyPath = path.join(dataDir, 'config.json');
  if (fs.existsSync(legacyPath)) {
    try {
      const raw = fs.readFileSync(legacyPath, 'utf8');
      const parsed = JSON.parse(raw) as PersistedConfigSnapshot;
      if (parsed && typeof parsed === 'object') {
        store.importSnapshotIfEmpty(parsed);
      }
    } catch {
      // Ignore unreadable legacy file
    }
  }
  return store;
}

/**
 * Creates a SQLite-backed `SecretVault` for Node.js with synchronous AES-256-GCM persistence,
 * automatically migrating any legacy `<dataDir>/vault.enc.json` + `.vault-key` into SQLite.
 */
export function createNodeSecretVault(
  sql: ISqlDatabase,
  dataDir: string,
  explicitSecret?: string,
): SecretVault {
  let legacyKeyBytes: Uint8Array | undefined;
  const legacyKeyPath = path.join(dataDir, '.vault-key');
  const resolvedSecret =
    explicitSecret?.trim() ||
    process.env.CHARKLE_VAULT_KEY?.trim() ||
    process.env.CHARKLE_VAULT_SECRET?.trim();

  if (!resolvedSecret && fs.existsSync(legacyKeyPath)) {
    try {
      const hex = fs.readFileSync(legacyKeyPath, 'utf8').trim();
      const buf = Buffer.from(hex, 'hex');
      if (buf.length === 32) {
        legacyKeyBytes = new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
      }
    } catch {
      // Ignore
    }
  }

  const vault = new SecretVault(sql, {
    masterKeySecret: resolvedSecret || undefined,
    rawMasterKeyBytes: legacyKeyBytes,
    syncCrypto: nodeSyncVaultCrypto,
  });

  // Migrate legacy `<dataDir>/vault.enc.json` if present
  const legacyVaultPath = path.join(dataDir, 'vault.enc.json');
  if (fs.existsSync(legacyVaultPath)) {
    try {
      const raw = fs.readFileSync(legacyVaultPath, 'utf8');
      const payload = JSON.parse(raw) as EncryptedVaultPayload;
      const decryptKey = resolvedSecret
        ? new Uint8Array(crypto.createHash('sha256').update(resolvedSecret, 'utf8').digest())
        : legacyKeyBytes;
      if (decryptKey && payload?.version === 1) {
        const plain = nodeSyncVaultCrypto.decrypt(decryptKey, payload);
        if (plain) {
          const parsed = JSON.parse(plain) as Record<string, string>;
          if (parsed && typeof parsed === 'object') {
            vault.importEntriesIfMissing(parsed);
          }
        }
      }
    } catch {
      // Ignore unreadable legacy vault
    }
  }

  return vault;
}
