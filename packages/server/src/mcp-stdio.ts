import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';
import { EventBus } from './api/events.js';
import { ExternalAgentService } from './agent/external-agent-service.js';
import { LibraryDatabase } from './db/library-database.js';
import {
  ChatGPTSubscriptionClient,
  createCloudAIProvider,
} from './intelligence/cloud-ai-provider.js';
import { CloudAIUsageTracker } from './intelligence/cloud-ai-usage-tracker.js';
import { VisualGroundingEngine } from './intelligence/visual-grounding-engine.js';
import { MediaPipeline } from './media/media-pipeline.js';
import { ConfigStore } from './storage/config-store.js';
import { SECRET_KEYS, SecretVault } from './storage/secret-vault.js';

export interface StdioMCPOptions {
  dataDir?: string;
  input?: NodeJS.ReadableStream;
  output?: NodeJS.WritableStream;
}

/**
 * Resolves the active SQLite library file inside `dataDir`, matching `app.ts`
 * (`charkle.sqlite` default, with fallback check for legacy names).
 */
export function resolveDatabasePath(dataDir: string): string {
  const candidates = ['charkle.sqlite', 'library.sqlite', 'charkle.db', 'library.db'];
  for (const name of candidates) {
    const candidate = path.join(dataDir, name);
    if (fs.existsSync(candidate)) return candidate;
  }
  return path.join(dataDir, 'charkle.sqlite');
}

/**
 * Creates a standalone `ExternalAgentService` wired directly against `dataDir`
 * for stdio JSON-RPC 2.0 MCP usage (Claude Desktop, Cursor, Antigravity, etc.).
 */
export function createStdioMCPService(dataDir: string): {
  service: ExternalAgentService;
  close: () => void;
} {
  const resolvedDir = path.resolve(dataDir);
  fs.mkdirSync(resolvedDir, { recursive: true });

  const configStore = new ConfigStore(resolvedDir);
  const secretVault = new SecretVault(resolvedDir);
  const db = new LibraryDatabase(resolveDatabasePath(resolvedDir));
  const media = new MediaPipeline(path.join(resolvedDir, 'media'), configStore.getCacheBudgetBytes());
  const events = new EventBus();
  const usage = new CloudAIUsageTracker(db);
  const chatGPT = new ChatGPTSubscriptionClient({
    vault: secretVault,
    stateStore: db,
    configStore,
    usage,
  });
  const grounding = new VisualGroundingEngine({ usage });

  const service = new ExternalAgentService({
    db,
    media,
    configStore,
    events,
    getCloudAIProvider: () =>
      createCloudAIProvider(configStore.getAIConfig(), {
        vault: secretVault,
        chatGPTClient: chatGPT,
        usage,
      }),
    getTypeSafeAPIKey: () =>
      secretVault.get(SECRET_KEYS.TYPESAFE_API_KEY) ?? (process.env.TYPESAFE_API_KEY?.trim() || null),
    grounding,
  });

  return {
    service,
    close: () => db.close(),
  };
}

/**
 * Runs a newline-delimited JSON-RPC 2.0 MCP server over stdio (`stdin` / `stdout`).
 */
export async function runStdioMCPServer(options: StdioMCPOptions = {}): Promise<void> {
  const dataDir = options.dataDir ?? process.env.CHARKLE_DATA_DIR ?? path.resolve('.charkle-data');
  const input = options.input ?? process.stdin;
  const output = options.output ?? process.stdout;
  const { service, close } = createStdioMCPService(dataDir);

  const rl = readline.createInterface({ input, crlfDelay: Infinity });

  try {
    for await (const rawLine of rl) {
      const line = rawLine.trim();
      if (!line) continue;
      const response = await service.handleJSONRPC(line);
      if (response !== null) {
        output.write(`${JSON.stringify(response)}\n`);
      }
    }
  } finally {
    rl.close();
    close();
  }
}

const isMain =
  process.argv[1] !== undefined &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;

if (isMain) {
  runStdioMCPServer().catch((err) => {
    process.stderr.write(`Charkle MCP stdio error: ${err instanceof Error ? err.message : String(err)}\n`);
    process.exit(1);
  });
}
