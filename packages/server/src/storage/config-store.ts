import {
  createDefaultAIProviderConfig,
  createDefaultDriveSyncConfig,
  createDefaultExternalAgentConfig,
  createDefaultTypeSafeExperimentalConfig,
  type AIProviderConfig,
  type ChatGPTAccountSession,
  type DriveSyncConfig,
  type ExternalAgentConfig,
  type TypeSafeExperimentalConfig,
} from '@charkle/shared';
import type { ISqlDatabase } from '../runtime/types.js';

export const DEFAULT_CACHE_BUDGET_BYTES = 10 * 1024 * 1024 * 1024; // 10 GiB

export interface PersistedConfigSnapshot {
  version?: number;
  aiConfig?: AIProviderConfig;
  typeSafeConfig?: TypeSafeExperimentalConfig;
  syncConfig?: DriveSyncConfig;
  externalAgentConfig?: ExternalAgentConfig;
  cacheBudgetBytes?: number;
  chatGPTSession?: ChatGPTAccountSession;
  custom?: Record<string, unknown>;
}

const KEY_AI = 'config.ai';
const KEY_TYPESAFE = 'config.typesafe';
const KEY_SYNC = 'config.sync';
const KEY_EXTERNAL_AGENT = 'config.externalAgent';
const KEY_CACHE_BUDGET = 'config.cacheBudgetBytes';
const KEY_CHATGPT_SESSION = 'config.chatGPTSession';
const KEY_CUSTOM_PREFIX = 'config.custom.';

export interface ConfigStoreOptions {
  defaultLocalLibraryPath?: string;
}

/**
 * Runtime-agnostic configuration store backed by `ISqlDatabase` (`sync_state` table).
 * Works identically on Node.js SQLite and Cloudflare Durable Object SQLite.
 */
export class ConfigStore {
  private readonly sql: ISqlDatabase;
  private readonly defaultLocalLibraryPath: string;

  constructor(sql: ISqlDatabase, options: ConfigStoreOptions = {}) {
    this.sql = sql;
    this.defaultLocalLibraryPath = options.defaultLocalLibraryPath ?? '.charkle-data/library';
    this.sql.exec('CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, payload TEXT NOT NULL);');
  }

  private readState<T>(key: string): T | null {
    const row = this.sql.get<{ payload: string }>(
      'SELECT payload FROM sync_state WHERE key = ?',
      [key],
    );
    if (!row) return null;
    try {
      return JSON.parse(row.payload) as T;
    } catch {
      return null;
    }
  }

  private writeState(key: string, value: unknown | null): void {
    if (value === null || value === undefined) {
      this.sql.run('DELETE FROM sync_state WHERE key = ?', [key]);
    } else {
      this.sql.run(
        'INSERT OR REPLACE INTO sync_state (key, payload) VALUES (?, ?)',
        [key, JSON.stringify(value)],
      );
    }
  }

  /**
   * Imports an initial config snapshot (e.g. migrating legacy Node `<dataDir>/config.json`)
   * without overwriting keys that are already persisted in SQLite.
   */
  importSnapshotIfEmpty(snapshot: PersistedConfigSnapshot): void {
    if (snapshot.aiConfig && this.readState(KEY_AI) === null) {
      this.setAIConfig(snapshot.aiConfig);
    }
    if (snapshot.typeSafeConfig && this.readState(KEY_TYPESAFE) === null) {
      this.setTypeSafeConfig(snapshot.typeSafeConfig);
    }
    if (snapshot.syncConfig && this.readState(KEY_SYNC) === null) {
      this.setSyncConfig(snapshot.syncConfig);
    }
    if (snapshot.externalAgentConfig && this.readState(KEY_EXTERNAL_AGENT) === null) {
      this.setExternalAgentConfig(snapshot.externalAgentConfig);
    }
    if (
      typeof snapshot.cacheBudgetBytes === 'number' &&
      this.readState(KEY_CACHE_BUDGET) === null
    ) {
      this.setCacheBudgetBytes(snapshot.cacheBudgetBytes);
    }
    if (snapshot.chatGPTSession && this.readState(KEY_CHATGPT_SESSION) === null) {
      this.setChatGPTSession(snapshot.chatGPTSession);
    }
    if (snapshot.custom && typeof snapshot.custom === 'object') {
      for (const [k, v] of Object.entries(snapshot.custom)) {
        if (this.readState(`${KEY_CUSTOM_PREFIX}${k}`) === null && v !== undefined) {
          this.set(k, v);
        }
      }
    }
  }

  getAIConfig(): AIProviderConfig {
    return createDefaultAIProviderConfig(this.readState<AIProviderConfig>(KEY_AI) ?? {});
  }

  setAIConfig(config: AIProviderConfig): AIProviderConfig {
    const merged = createDefaultAIProviderConfig(config);
    this.writeState(KEY_AI, merged);
    return merged;
  }

  getTypeSafeConfig(): TypeSafeExperimentalConfig {
    return createDefaultTypeSafeExperimentalConfig(
      this.readState<TypeSafeExperimentalConfig>(KEY_TYPESAFE) ?? {},
    );
  }

  setTypeSafeConfig(config: TypeSafeExperimentalConfig): TypeSafeExperimentalConfig {
    const merged = createDefaultTypeSafeExperimentalConfig(config);
    this.writeState(KEY_TYPESAFE, merged);
    return merged;
  }

  getSyncConfig(): DriveSyncConfig {
    const stored = this.readState<DriveSyncConfig>(KEY_SYNC);
    return createDefaultDriveSyncConfig({
      localLibraryPath: this.defaultLocalLibraryPath,
      ...(stored ?? {}),
    });
  }

  setSyncConfig(config: DriveSyncConfig): DriveSyncConfig {
    const merged = createDefaultDriveSyncConfig({
      ...config,
      localLibraryPath: config.localLibraryPath || this.defaultLocalLibraryPath,
    });
    this.writeState(KEY_SYNC, merged);
    return merged;
  }

  getExternalAgentConfig(): ExternalAgentConfig {
    return createDefaultExternalAgentConfig(
      this.readState<ExternalAgentConfig>(KEY_EXTERNAL_AGENT) ?? {},
    );
  }

  setExternalAgentConfig(config: ExternalAgentConfig): ExternalAgentConfig {
    const merged = createDefaultExternalAgentConfig(config);
    this.writeState(KEY_EXTERNAL_AGENT, merged);
    return merged;
  }

  getCacheBudgetBytes(): number {
    const v = this.readState<number>(KEY_CACHE_BUDGET);
    if (typeof v === 'number' && Number.isFinite(v) && v > 0) {
      return Math.round(v);
    }
    return DEFAULT_CACHE_BUDGET_BYTES;
  }

  setCacheBudgetBytes(bytes: number): number {
    const clamped = Math.max(1024 * 1024, Math.round(bytes)); // min 1 MiB for tests & safety
    this.writeState(KEY_CACHE_BUDGET, clamped);
    return clamped;
  }

  getChatGPTSession(): ChatGPTAccountSession {
    return (
      this.readState<ChatGPTAccountSession>(KEY_CHATGPT_SESSION) ?? {
        status: 'disconnected',
        sharingEnabled: false,
        email: null,
        name: null,
        subject: null,
        lastUpdatedAt: null,
      }
    );
  }

  setChatGPTSession(session: ChatGPTAccountSession): ChatGPTAccountSession {
    const copy = { ...session };
    this.writeState(KEY_CHATGPT_SESSION, copy);
    return copy;
  }

  get<T = unknown>(key: string): T | null {
    return this.readState<T>(`${KEY_CUSTOM_PREFIX}${key}`);
  }

  set<T = unknown>(key: string, value: T | null): void {
    this.writeState(`${KEY_CUSTOM_PREFIX}${key}`, value);
  }
}
