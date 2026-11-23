import type { IPasswordHasher } from './types.js';
import {
  bytesToHex,
  hexToBytes,
  randomBytes,
  timingSafeEqualBytes,
  toArrayBuffer,
  utf8Encode,
} from './web-crypto-utils.js';

export const PBKDF2_DEFAULT_ITERATIONS = 100_000;
export const PBKDF2_MAX_ITERATIONS = 100_000; // Cloudflare Workers Web Crypto hard cap
export const PBKDF2_SALT_BYTES = 16;
export const PBKDF2_KEY_BYTES = 32;

export type LegacyScryptVerifier = (
  password: string,
  storedHash: string,
  legacySalt?: string,
) => Promise<boolean> | boolean;

export interface WebCryptoPasswordHasherOptions {
  iterations?: number;
  legacyScryptVerifier?: LegacyScryptVerifier;
}

/**
 * Hardware-accelerated Web Crypto `PBKDF2-SHA256` password hasher.
 * Works identically on BOTH Node 26 and Cloudflare Workers (`100,000` iterations).
 *
 * Wire format: `pbkdf2$<iterations>$<saltHex>$<hashHex>`
 *
 * Also supports verifying legacy `scrypt$...` or bare Node scrypt hashes when a
 * `legacyScryptVerifier` callback is injected on Node.
 */
export class WebCryptoPasswordHasher implements IPasswordHasher {
  public readonly iterations: number;
  private readonly legacyScryptVerifier?: LegacyScryptVerifier;

  constructor(options: WebCryptoPasswordHasherOptions = {}) {
    const requested = Math.trunc(options.iterations ?? PBKDF2_DEFAULT_ITERATIONS);
    this.iterations = Math.max(10_000, Math.min(PBKDF2_MAX_ITERATIONS, requested));
    this.legacyScryptVerifier = options.legacyScryptVerifier;
  }

  async hash(password: string): Promise<string> {
    const salt = randomBytes(PBKDF2_SALT_BYTES);
    const derived = await derivePbkdf2Sha256(password, salt, this.iterations, PBKDF2_KEY_BYTES);
    return `pbkdf2$${this.iterations}$${bytesToHex(salt)}$${bytesToHex(derived)}`;
  }

  async verify(password: string, storedHash: string, legacySalt?: string): Promise<boolean> {
    if (!storedHash || typeof storedHash !== 'string') return false;

    if (storedHash.startsWith('pbkdf2$')) {
      const parts = storedHash.split('$');
      if (parts.length !== 4) return false;
      const iterations = Number.parseInt(parts[1], 10);
      if (
        !Number.isFinite(iterations) ||
        iterations < 1000 ||
        iterations > PBKDF2_MAX_ITERATIONS
      ) {
        return false;
      }
      try {
        const salt = hexToBytes(parts[2]);
        const expected = hexToBytes(parts[3]);
        if (salt.byteLength < 8 || expected.byteLength < 16) return false;
        const derived = await derivePbkdf2Sha256(password, salt, iterations, expected.byteLength);
        return timingSafeEqualBytes(derived, expected);
      } catch {
        return false;
      }
    }

    // Legacy Node `scrypt$...` or bare scrypt hex + separate `password_salt` column
    if (this.legacyScryptVerifier) {
      return Boolean(await this.legacyScryptVerifier(password, storedHash, legacySalt));
    }

    return false;
  }
}

export async function derivePbkdf2Sha256(
  password: string,
  salt: Uint8Array,
  iterations: number,
  keyBytes: number,
): Promise<Uint8Array> {
  const keyMaterial = await globalThis.crypto.subtle.importKey(
    'raw',
    toArrayBuffer(utf8Encode(password)),
    'PBKDF2',
    false,
    ['deriveBits'],
  );
  const bits = await globalThis.crypto.subtle.deriveBits(
    {
      name: 'PBKDF2',
      hash: 'SHA-256',
      salt: toArrayBuffer(salt),
      iterations,
    },
    keyMaterial,
    keyBytes * 8,
  );
  return new Uint8Array(bits);
}
