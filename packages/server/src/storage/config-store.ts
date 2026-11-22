import fs from 'node:fs';
import path from 'node:path';
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

export const DEFAULT_CACHE_BUDGET_BYTES = 10 * 1024 * 1024 * 1024; // 10 GiB

interface PersistedConfigFile {
  version: number;
  aiConfig?: AIProviderConfig;
  typeSafeConfig?: TypeSafeExperimentalConfig;
  syncConfig?: DriveSyncConfig;
  externalAgentConfig?: ExternalAgentConfig;
  cacheBudgetBytes?: number;
  chatGPTSession?: ChatGPTAccountSession;
  custom?: Record<string, unknown>;
}

/**
 * Atomic JSON configuration store persisted under `<dataDir>/config.json`.
 */
export class ConfigStore {
  private readonly filePath: string;
  private readonly dataDir: string;
  private data: PersistedConfigFile;

  constructor(dataDir: string) {
    this.dataDir = dataDir;
    fs.mkdirSync(dataDir, { recursive: true });
    this.filePath = path.join(dataDir, 'config.json');
    this.data = this.loadFromDisk();
  }

  private loadFromDisk(): PersistedConfigFile {
    try {
      if (fs.existsSync(this.filePath)) {
        const raw = fs.readFileSync(this.filePath, 'utf8');
        const parsed = JSON.parse(raw) as Partial<PersistedConfigFile>;
        if (parsed && typeof parsed === 'object') {
          return { ...parsed, version: parsed.version ?? 1 };
        }
      }
    } catch {
      // Recover cleanly with defaults if config file was corrupted.
    }
    return { version: 1 };
  }

  private persist(): void {
    fs.mkdirSync(this.dataDir, { recursive: true });
    const tmpPath = `${this.filePath}.${process.pid}.${Date.now()}.tmp`;
    fs.writeFileSync(tmpPath, JSON.stringify(this.data, null, 2) + '\n', { mode: 0o600 });
    fs.renameSync(tmpPath, this.filePath);
  }

  getAIConfig(): AIProviderConfig {
    return createDefaultAIProviderConfig(this.data.aiConfig ?? {});
  }

  setAIConfig(config: AIProviderConfig): AIProviderConfig {
    const merged = createDefaultAIProviderConfig(config);
    this.data.aiConfig = merged;
    this.persist();
    return merged;
  }

  getTypeSafeConfig(): TypeSafeExperimentalConfig {
    return createDefaultTypeSafeExperimentalConfig(this.data.typeSafeConfig ?? {});
  }

  setTypeSafeConfig(config: TypeSafeExperimentalConfig): TypeSafeExperimentalConfig {
    const merged = createDefaultTypeSafeExperimentalConfig(config);
    this.data.typeSafeConfig = merged;
    this.persist();
    return merged;
  }

  getSyncConfig(): DriveSyncConfig {
    const defaultLibraryPath = path.join(this.dataDir, 'library');
    return createDefaultDriveSyncConfig({
      localLibraryPath: defaultLibraryPath,
      ...(this.data.syncConfig ?? {}),
    });
  }

  setSyncConfig(config: DriveSyncConfig): DriveSyncConfig {
    const defaultLibraryPath = path.join(this.dataDir, 'library');
    const merged = createDefaultDriveSyncConfig({
      ...config,
      localLibraryPath: config.localLibraryPath || defaultLibraryPath,
    });
    this.data.syncConfig = merged;
    this.persist();
    return merged;
  }

  getExternalAgentConfig(): ExternalAgentConfig {
    return createDefaultExternalAgentConfig(this.data.externalAgentConfig ?? {});
  }

  setExternalAgentConfig(config: ExternalAgentConfig): ExternalAgentConfig {
    const merged = createDefaultExternalAgentConfig(config);
    this.data.externalAgentConfig = merged;
    this.persist();
    return merged;
  }

  getCacheBudgetBytes(): number {
    const v = this.data.cacheBudgetBytes;
    if (typeof v === 'number' && Number.isFinite(v) && v > 0) {
      return Math.round(v);
    }
    return DEFAULT_CACHE_BUDGET_BYTES;
  }

  setCacheBudgetBytes(bytes: number): number {
    const clamped = Math.max(1024 * 1024, Math.round(bytes)); // min 1 MiB for tests & safety
    this.data.cacheBudgetBytes = clamped;
    this.persist();
    return clamped;
  }

  getChatGPTSession(): ChatGPTAccountSession {
    return (
      this.data.chatGPTSession ?? {
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
    this.data.chatGPTSession = { ...session };
    this.persist();
    return this.data.chatGPTSession;
  }

  get<T = unknown>(key: string): T | null {
    if (!this.data.custom || !(key in this.data.custom)) return null;
    return this.data.custom[key] as T;
  }

  set<T = unknown>(key: string, value: T | null): void {
    if (!this.data.custom) this.data.custom = {};
    if (value === null || value === undefined) {
      delete this.data.custom[key];
    } else {
      this.data.custom[key] = value;
    }
    this.persist();
  }
}
