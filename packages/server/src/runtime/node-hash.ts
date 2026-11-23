import crypto from 'node:crypto';
import type { IPasswordHasher } from './types.js';
import {
  PBKDF2_DEFAULT_ITERATIONS,
  PBKDF2_KEY_BYTES,
  PBKDF2_SALT_BYTES,
  WebCryptoPasswordHasher,
} from './web-crypto-hash.js';

const LEGACY_SCRYPT_KEYLEN = 64;
const LEGACY_SCRYPT_PARAMS: crypto.ScryptOptions = { N: 16384, r: 8, p: 1 };

export function verifyLegacyNodeScrypt(
  password: string,
  storedHash: string,
  legacySalt?: string,
): boolean {
  try {
    // Support self-describing `scrypt$<saltHex>$<hashHex>` OR `scrypt$<N>$<r>$<p>$<saltHex>$<hashHex>`
    if (storedHash.startsWith('scrypt$')) {
      const parts = storedHash.split('$');
      let salt: string;
      let expectedHex: string;
      let params: crypto.ScryptOptions = LEGACY_SCRYPT_PARAMS;
      if (parts.length === 3) {
        salt = parts[1];
        expectedHex = parts[2];
      } else if (parts.length === 6) {
        params = {
          N: Number.parseInt(parts[1], 10) || 16384,
          r: Number.parseInt(parts[2], 10) || 8,
          p: Number.parseInt(parts[3], 10) || 1,
        };
        salt = parts[4];
        expectedHex = parts[5];
      } else {
        return false;
      }
      const expected = Buffer.from(expectedHex, 'hex');
      if (expected.length === 0) return false;
      const derived = crypto.scryptSync(password, salt, expected.length, params);
      if (derived.length !== expected.length) return false;
      return crypto.timingSafeEqual(derived, expected);
    }

    // Legacy Charkle DB schema: bare 128-hex scrypt hash + separate `password_salt` column
    if (legacySalt && legacySalt.length > 0 && /^[0-9a-fA-F]+$/.test(storedHash)) {
      const expected = Buffer.from(storedHash, 'hex');
      const keyLen = expected.length || LEGACY_SCRYPT_KEYLEN;
      const derived = crypto.scryptSync(password, legacySalt, keyLen, LEGACY_SCRYPT_PARAMS);
      if (derived.length !== expected.length) return false;
      return crypto.timingSafeEqual(derived, expected);
    }
  } catch {
    return false;
  }
  return false;
}

/**
 * Node.js password hasher producing standard Web Crypto `pbkdf2$100000$<saltHex>$<hashHex>`
 * hashes (100% portable with Cloudflare Workers) while seamlessly verifying legacy Node
 * `scrypt` password hashes without forcing password resets.
 */
export class NodePasswordHasher implements IPasswordHasher {
  private readonly webHasher: WebCryptoPasswordHasher;

  constructor(iterations: number = PBKDF2_DEFAULT_ITERATIONS) {
    this.webHasher = new WebCryptoPasswordHasher({
      iterations,
      legacyScryptVerifier: verifyLegacyNodeScrypt,
    });
  }

  hash(password: string): Promise<string> {
    return this.webHasher.hash(password);
  }

  verify(password: string, storedHash: string, legacySalt?: string): Promise<boolean> {
    return this.webHasher.verify(password, storedHash, legacySalt);
  }

  hashSync(password: string): string {
    const salt = crypto.randomBytes(PBKDF2_SALT_BYTES);
    const derived = crypto.pbkdf2Sync(
      password,
      salt,
      this.webHasher.iterations,
      PBKDF2_KEY_BYTES,
      'sha256',
    );
    return `pbkdf2$${this.webHasher.iterations}$${salt.toString('hex')}$${derived.toString('hex')}`;
  }
}
