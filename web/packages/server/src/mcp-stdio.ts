import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import type { ExternalAgentChannel } from '@charkle/shared';
import { EventBus } from './api/events.js';
import { ExternalAgentService } from './agent/external-agent-service.js';
import {
  ChatGPTSubscriptionClient,
  createCloudAIProvider,
} from './intelligence/cloud-ai-provider.js';
import { CloudAIUsageTracker } from './intelligence/cloud-ai-usage-tracker.js';
import { VisualGroundingEngine } from './intelligence/visual-grounding-engine.js';
import { MCPStdioFrameParser, type MCPStdioFrameEvent } from './mcp/stdio-frame-parser.js';
import { MediaPipeline } from './media/media-pipeline.js';
import { NodeBlobStore } from './runtime/node-blob.js';
import { NodeImageProcessor } from './runtime/node-image.js';
import { openNodeLibraryDatabase } from './runtime/node-sql.js';
import { createNodeConfigStore, createNodeSecretVault } from './runtime/node-storage.js';
import { utf8Decode, utf8Encode } from './runtime/web-crypto-utils.js';
import { SECRET_KEYS } from './storage/secret-vault.js';

export interface StdioMCPOptions {
  dataDir?: string;
  input?: NodeJS.ReadableStream;
  output?: NodeJS.WritableStream;
  channel?: ExternalAgentChannel;
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
 * for stdio JSON-RPC 2.0 MCP usage (Claude Code, Codex, MCP clients).
 */
export function createStdioMCPService(dataDir: string): {
  service: ExternalAgentService;
  close: () => void;
} {
  const resolvedDir = path.resolve(dataDir);
  fs.mkdirSync(resolvedDir, { recursive: true });

  const db = openNodeLibraryDatabase(resolveDatabasePath(resolvedDir));
  const configStore = createNodeConfigStore(db.sql, resolvedDir);
  const secretVault = createNodeSecretVault(db.sql, resolvedDir);
  const blobs = new NodeBlobStore(path.join(resolvedDir, 'media'));
  const images = new NodeImageProcessor();
  const media = new MediaPipeline({
    blobs,
    images,
    cacheBudgetBytes: configStore.getCacheBudgetBytes(),
    readLocalFile: async (filePath: string) => new Uint8Array(await fsp.readFile(filePath)),
  });
  const events = new EventBus();
  const usage = new CloudAIUsageTracker(db);
  const chatGPT = new ChatGPTSubscriptionClient({
    vault: secretVault,
    stateStore: db,
    configStore,
    usage,
  });
  const grounding = new VisualGroundingEngine({ usage, images });

  const service = new ExternalAgentService({
    db,
    media,
    configStore,
    events,
    runtimeMode: 'node',
    getCloudAIProvider: () =>
      createCloudAIProvider(configStore.getAIConfig(), {
        vault: secretVault,
        chatGPTClient: chatGPT,
        usage,
      }),
    getTypeSafeAPIKey: () =>
      secretVault.get(SECRET_KEYS.TYPESAFE_API_KEY) ?? (process.env.TYPESAFE_API_KEY?.trim() || null),
    grounding,
    localFs: {
      existsSync: (filePath: string) => fs.existsSync(filePath),
      resolvePath: (filePath: string) => path.resolve(filePath),
      writeFileSync: (filePath: string, data: Uint8Array) => fs.writeFileSync(filePath, data),
    },
  });

  return {
    service,
    close: () => db.close(),
  };
}

/**
 * Runs a chunk-safe JSON-RPC 2.0 MCP server over stdio (`stdin` / `stdout`),
 * seamlessly supporting both `NDJSON` and `Content-Length` framing and replying in matching framing.
 */
export async function runStdioMCPServer(options: StdioMCPOptions = {}): Promise<void> {
  const dataDir = options.dataDir ?? process.env.CHARKLE_DATA_DIR ?? path.resolve('.charkle-data');
  const input = options.input ?? process.stdin;
  const output = options.output ?? process.stdout;
  const channel: ExternalAgentChannel = options.channel ?? 'mcp';
  const { service, close } = createStdioMCPService(dataDir);
  const parser = new MCPStdioFrameParser();

  const dispatchEvent = async (event: MCPStdioFrameEvent): Promise<void> => {
    if (event.type === 'invalidFrame') {
      const errBytes = utf8Encode(
        JSON.stringify({
          jsonrpc: '2.0',
          id: null,
          error: { code: -32700, message: event.reason },
        }),
      );
      output.write(MCPStdioFrameParser.encode(errBytes, event.framing));
      return;
    }

    const text = utf8Decode(event.payload).trim();
    if (!text) return;
    const response = await service.handleJSONRPC(text, channel);
    if (response !== null) {
      const respBytes = utf8Encode(JSON.stringify(response));
      output.write(MCPStdioFrameParser.encode(respBytes, event.framing));
    }
  };

  try {
    for await (const rawChunk of input) {
      const bytes =
        rawChunk instanceof Uint8Array
          ? rawChunk
          : typeof rawChunk === 'string'
            ? utf8Encode(rawChunk)
            : new Uint8Array(Buffer.from(rawChunk as ArrayBufferLike));
      const events = parser.append(bytes);
      for (const ev of events) {
        await dispatchEvent(ev);
      }
    }
    const trailing = parser.finishEOF();
    for (const ev of trailing) {
      await dispatchEvent(ev);
    }
  } finally {
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
