import {
  ASPECT_SHAPES,
  createDefaultAssetBatchPatch,
  createDefaultAutoLayoutConfig,
  createDefaultFilterCriteria,
  createDefaultMoodboardCurationRequest,
  EDITORIAL_STYLES,
  externalAgentAllowsRead,
  externalAgentAllowsWrite,
  flattenFolderTree,
  formatPhotoExifAperture,
  getAssetAspectRatio,
  getAssetAspectShape,
  getAssetDisplayTypeLabel,
  getBoardReferencedAssetIDs,
  getEffectiveSocialAttachments,
  getPhotoExifCameraDisplayName,
  getPhotoExifExposureSummary,
  GROUP_TINTS,
  hasMeaningfulCameraExif,
  isAIGenerationEmpty,
  isMeaningfulCropSubregion,
  isPhotoExifEmpty,
  labFromHex,
  matchesSmartFolderRule,
  MEDIA_KINDS,
  NOTE_STYLES,
  toSwiftUUID,
  type AspectShape,
  type AssetRecord,
  type AssetRichMetadata,
  type BoardLayoutMode,
  type BoardNode,
  type BoardRect,
  type CaptureInput,
  type EditorialStyle,
  type ExternalAgentChannel,
  type ExternalAgentConfig,
  type ExternalAgentDiagnosticsResponse,
  type FilterCriteria,
  type FolderAssignment,
  type FolderRecord,
  type GroupTint,
  type MediaKind,
  type MoodboardDocument,
  type NoteStyle,
  type RuntimeMode,
  type SmartFolderRecord,
  type SortOrder,
  type UUID,
} from '@charkle/shared';
import type { EventBus } from '../api/events.js';
import type { IMediaPipeline, ServerContext } from '../context.js';
import { encodeFeaturePrintFloat32, type LibraryDatabase } from '../db/library-database.js';
import type { CloudAIProvider } from '../intelligence/cloud-ai-provider.js';
import {
  buildFolderPathsMap,
  CharkleAgentTools,
  MoodboardAgentHarness,
  type AgentBoardPlan,
  type AgentRecallResult,
  type AgentSectionSpec,
  type AgentSlotPick,
} from '../intelligence/moodboard-agent-harness.js';
import { MoodboardCurator } from '../intelligence/moodboard-curator.js';
import {
  VisualGroundingEngine,
  VisualGroundingService,
} from '../intelligence/visual-grounding-engine.js';
import { bytesToBase64, randomUUID } from '../runtime/web-crypto-utils.js';
import { sniffImageMimeType } from '../runtime/workers-image.js';
import type { ConfigStore } from '../storage/config-store.js';
import {
  MCP_DEFAULT_PROTOCOL_VERSION,
  MCP_SERVER_VERSION,
  MCP_SUPPORTED_PROTOCOL_VERSIONS,
  MCP_WRITE_TOOL_NAMES,
  mcpPromptDefinitions,
  mcpResourceDefinitions,
  mcpResourceTemplateDefinitions,
  mcpToolDefinitions,
  negotiateProtocolVersion,
  renderPrompt,
} from './external-agent-schema.js';

export type MCPToolContent =
  | { type: 'text'; text: string }
  | { type: 'image'; mimeType: string; data: string };

export interface MCPToolOutput {
  content: MCPToolContent[];
  isError: boolean;
}

export interface ExternalAgentServiceDeps {
  db: LibraryDatabase;
  media: IMediaPipeline;
  configStore: ConfigStore;
  events: EventBus;
  runtimeMode?: RuntimeMode;
  localFs?: ServerContext['localFs'];
  getCloudAIProvider?: () => CloudAIProvider | null;
  getTypeSafeAPIKey?: () => string | null;
  grounding?: VisualGroundingEngine | null;
  groundingService?: VisualGroundingService | null;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function asString(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

function asTrimmedString(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return t.length > 0 ? t : null;
}

function asBool(v: unknown): boolean | null {
  if (typeof v === 'boolean') return v;
  if (typeof v === 'string') {
    const low = v.trim().toLowerCase();
    if (low === 'true' || low === '1' || low === 'yes') return true;
    if (low === 'false' || low === '0' || low === 'no') return false;
  }
  return null;
}

function asNumber(v: unknown): number | null {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && v.trim().length > 0) {
    const n = Number(v);
    if (Number.isFinite(n)) return n;
  }
  return null;
}

function asInt(v: unknown): number | null {
  const n = asNumber(v);
  return n === null ? null : Math.trunc(n);
}

function asStringArray(v: unknown): string[] | null {
  if (!Array.isArray(v)) return null;
  return v.filter((x): x is string => typeof x === 'string');
}

function parseUUID(raw: unknown): UUID | null {
  const s = asTrimmedString(raw);
  if (!s || !UUID_RE.test(s)) return null;
  return toSwiftUUID(s);
}

function parseUUIDList(raw: unknown): UUID[] {
  const arr = asStringArray(raw) ?? [];
  const out: UUID[] = [];
  for (const item of arr) {
    const id = parseUUID(item);
    if (id) out.push(id);
  }
  return out;
}

function parseMediaKinds(raw: unknown): MediaKind[] {
  const out: MediaKind[] = [];
  for (const k of asStringArray(raw) ?? []) {
    const trimmed = k.trim();
    if ((MEDIA_KINDS as readonly string[]).includes(trimmed)) {
      out.push(trimmed as MediaKind);
    }
  }
  return out;
}

function parseSortOrder(raw: unknown, defaultOrder: SortOrder): SortOrder {
  const s = asTrimmedString(raw)?.toLowerCase();
  if (!s) return defaultOrder;
  switch (s) {
    case 'newest':
      return 'newest';
    case 'oldest':
      return 'oldest';
    case 'name_asc':
    case 'nameasc':
    case 'name':
      return 'nameAsc';
    case 'rating_desc':
    case 'ratingdesc':
    case 'rating':
      return 'ratingDesc';
    case 'file_size_desc':
    case 'filesizedesc':
    case 'size':
      return 'fileSizeDesc';
    case 'relevance':
      return 'relevance';
    default:
      return defaultOrder;
  }
}

function paginate<T>(items: readonly T[], offset: number, limit: number): T[] {
  if (offset >= items.length) return [];
  return items.slice(offset, Math.min(items.length, offset + limit));
}

function layoutModeLabel(mode: BoardLayoutMode): string {
  return mode.type === 'autoEditorial' ? `autoEditorial(${mode.config.style})` : 'freeform';
}

function frameDict(f: BoardRect): Record<string, number> {
  return {
    x: Math.round(f.x),
    y: Math.round(f.y),
    width: Math.round(f.width),
    height: Math.round(f.height),
  };
}

function jsonToolOutput(obj: unknown, isError = false): MCPToolOutput {
  return {
    content: [{ type: 'text', text: JSON.stringify(obj, null, 2) }],
    isError,
  };
}

function errorToolOutput(message: string): MCPToolOutput {
  return {
    content: [{ type: 'text', text: message }],
    isError: true,
  };
}

function extractTextFromToolOutput(out: MCPToolOutput): string {
  return out.content
    .filter((c): c is { type: 'text'; text: string } => c.type === 'text')
    .map((c) => c.text)
    .join('\n');
}

/**
 * Grounded External Agent Service & MCP v2 JSON-RPC 2.0 Server
 * (20 Safe Tools · 4 Static + 2 Dynamic Resources · 4 Curated Studio Prompts · Batch JSON-RPC).
 * Powers BOTH HTTP `POST /api/v1/mcp` (Node & Cloudflare Workers) and stdio `mcp-stdio.ts`.
 */
export class ExternalAgentService {
  static readonly serverVersion = MCP_SERVER_VERSION;
  static readonly supportedProtocolVersions = MCP_SUPPORTED_PROTOCOL_VERSIONS;
  static readonly defaultProtocolVersion = MCP_DEFAULT_PROTOCOL_VERSION;
  static readonly negotiateProtocolVersion = negotiateProtocolVersion;
  static readonly mcpToolDefinitions = mcpToolDefinitions;
  static readonly mcpResourceDefinitions = mcpResourceDefinitions;
  static readonly mcpResourceTemplateDefinitions = mcpResourceTemplateDefinitions;
  static readonly mcpPromptDefinitions = mcpPromptDefinitions;
  static readonly renderPrompt = renderPrompt;

  private readonly deps: ExternalAgentServiceDeps;
  private readonly tools: CharkleAgentTools;
  private readonly curator: MoodboardCurator;
  private readonly harness: MoodboardAgentHarness;
  private readonly groundingService: VisualGroundingService;
  private readonly runtimeMode: RuntimeMode;

  constructor(deps: ExternalAgentServiceDeps) {
    this.deps = deps;
    this.runtimeMode = deps.runtimeMode ?? 'node';
    this.tools = new CharkleAgentTools(deps.db, deps.media);
    this.curator = new MoodboardCurator(deps.db);
    this.harness = new MoodboardAgentHarness(deps.db, deps.media);
    this.groundingService =
      deps.groundingService ??
      new VisualGroundingService({
        db: deps.db,
        media: deps.media,
        engine: deps.grounding ?? new VisualGroundingEngine({ images: deps.media.images }),
        getTypeSafeConfig: () => deps.configStore.getTypeSafeConfig(),
        getTypeSafeAPIKey: () => deps.getTypeSafeAPIKey?.() ?? null,
        getCloudAIProvider: () => {
          try {
            return deps.getCloudAIProvider?.() ?? null;
          } catch {
            return null;
          }
        },
      });
  }

  currentPolicy(): ExternalAgentConfig {
    return this.deps.configStore.getExternalAgentConfig();
  }

  // MARK: - Diagnostics (`GET /api/v1/agent/diagnostics`)

  async runDiagnostics(): Promise<ExternalAgentDiagnosticsResponse> {
    const policy = this.currentPolicy();
    const toolDefs = mcpToolDefinitions();
    const readToolCount = toolDefs.filter(
      (t) => ((t.annotations as Record<string, unknown> | undefined)?.readOnlyHint as boolean) === true,
    ).length;
    const writeToolCount = toolDefs.length - readToolCount;

    let ok = true;
    let error: string | undefined;
    let totalAssets = 0;
    let inboxCount = 0;
    let untaggedCount = 0;
    let trashedCount = 0;
    let folderCount = 0;
    let smartFolderCount = 0;
    let boardCount = 0;
    let syncMode = 'localOnly';
    let aiProvider = 'disabled';
    let cache = {
      thumbnailBytes: 0,
      originalCacheBytes: 0,
      pinnedOfflineBytes: 0,
      budgetBytes: this.deps.media.getCacheBudgetBytes(),
      cachedOriginalCount: 0,
      pinnedAssetCount: 0,
    };

    try {
      const overview = this.tools.libraryOverview();
      const smartFolders = this.deps.db.fetchSmartFolders();
      const syncCfg = this.deps.configStore.getSyncConfig();
      const aiCfg = this.deps.configStore.getAIConfig();
      cache = await this.deps.media.getCacheStats(this.deps.db);

      totalAssets = overview.totalAssets;
      inboxCount = overview.inboxCount;
      untaggedCount = this.deps.db.untaggedCount();
      trashedCount = this.deps.db.trashCount();
      folderCount = overview.folders.length;
      smartFolderCount = smartFolders.length;
      boardCount = overview.boardCount;
      syncMode = syncCfg.mode;
      aiProvider = aiCfg.provider;
    } catch (err) {
      ok = false;
      error = err instanceof Error ? err.message : String(err);
    }

    return {
      ok,
      serverVersion: MCP_SERVER_VERSION,
      runtimeMode: this.runtimeMode,
      supportedProtocolVersions: [...MCP_SUPPORTED_PROTOCOL_VERSIONS],
      policy: {
        mcpEnabled: policy.mcpEnabled,
        cliEnabled: policy.cliEnabled,
        accessLevel: policy.accessLevel,
        mcpCanWrite: externalAgentAllowsWrite(policy, 'mcp'),
        cliCanWrite: externalAgentAllowsWrite(policy, 'cli'),
      },
      capabilities: {
        toolCount: toolDefs.length,
        readToolCount,
        writeToolCount,
        resourceCount: mcpResourceDefinitions().length,
        resourceTemplateCount: mcpResourceTemplateDefinitions().length,
        promptCount: mcpPromptDefinitions().length,
        permanentDeleteAllowed: false,
      },
      library: {
        totalAssets,
        inboxCount,
        untaggedCount,
        trashedCount,
        folderCount,
        smartFolderCount,
        boardCount,
      },
      syncMode,
      aiProvider,
      cache,
      database: {
        healthy: ok,
        exists: true,
        sizeBytes: 0,
      },
      ...(error ? { error } : {}),
    };
  }

  // MARK: - JSON-RPC 2.0 Dispatcher (Single Object & Batch Array)

  async handleJSONRPC(
    payload: string | Record<string, unknown> | unknown[],
    channel: ExternalAgentChannel = 'mcp',
  ): Promise<Record<string, unknown> | Array<Record<string, unknown>> | null> {
    let parsed: unknown;
    if (typeof payload === 'string') {
      try {
        parsed = JSON.parse(payload);
      } catch {
        return this.makeErrorResponse(null, -32700, 'Parse error: invalid JSON');
      }
    } else {
      parsed = payload;
    }

    if (Array.isArray(parsed)) {
      if (parsed.length === 0) {
        return this.makeErrorResponse(null, -32600, 'Invalid Request: empty JSON-RPC batch');
      }
      const responses: Array<Record<string, unknown>> = [];
      for (const item of parsed) {
        if (item && typeof item === 'object' && !Array.isArray(item)) {
          const resp = await this.handleSingleJSONRPCObject(
            item as Record<string, unknown>,
            channel,
          );
          if (resp !== null) responses.push(resp);
        } else {
          responses.push(
            this.makeErrorResponse(null, -32600, 'Invalid Request: batch element must be an object'),
          );
        }
      }
      return responses.length > 0 ? responses : null;
    }

    if (!parsed || typeof parsed !== 'object') {
      return this.makeErrorResponse(
        null,
        -32600,
        'Invalid Request: expected JSON object or array',
      );
    }

    return this.handleSingleJSONRPCObject(parsed as Record<string, unknown>, channel);
  }

  private async handleSingleJSONRPCObject(
    obj: Record<string, unknown>,
    channel: ExternalAgentChannel,
  ): Promise<Record<string, unknown> | null> {
    const id = 'id' in obj ? obj.id : undefined;
    const isNotification = id === undefined || id === null;
    const method = asString(obj.method);
    if (!method) {
      return isNotification
        ? null
        : this.makeErrorResponse(id, -32600, 'Invalid Request: missing method');
    }

    const params =
      obj.params && typeof obj.params === 'object' && !Array.isArray(obj.params)
        ? (obj.params as Record<string, unknown>)
        : {};

    const disabledMessage =
      channel === 'cli'
        ? 'Charkle CLI service is disabled in Settings.'
        : 'Charkle MCP service is disabled in Settings.';

    switch (method) {
      case 'initialize': {
        const policy = this.currentPolicy();
        if (!externalAgentAllowsRead(policy, channel)) {
          return this.makeErrorResponse(id, -32001, disabledMessage);
        }
        const negotiatedVersion = negotiateProtocolVersion(asString(params.protocolVersion));
        return this.makeResultResponse(id, {
          protocolVersion: negotiatedVersion,
          capabilities: {
            tools: { listChanged: false },
            resources: { subscribe: false, listChanged: false },
            prompts: { listChanged: false },
            logging: {},
          },
          serverInfo: {
            name: 'charkle',
            version: MCP_SERVER_VERSION,
          },
          instructions:
            'Charkle is a visual reference library and moodboard studio. Start with `library_overview` to inspect folders, smart folders, and tags. Use `search_assets` (with pagination, subfolder recursion, color, media kind, and smart folder filters), `semantic_search`, `find_similar_assets`, `quick_jump`, or `list_inbox` to locate references. Use `render_contact_sheet` to visually inspect up to 16 numbered thumbnails in one image, `get_asset` (with optional `include_image: true`) for full EXIF, AI generation prompts, social post, and GitHub metadata, and `get_board_context` / `export_board_image` to inspect moodboards. Safe write tools (`organize_assets`, `create_folder`, `update_folder`, `ingest_asset`, `compose_moodboard`, `patch_moodboard`, `trash_assets`, `analyze_assets`) are available when write access is enabled in Charkle Settings; permanent deletion is never permitted.',
        });
      }

      case 'notifications/initialized':
      case 'notifications/cancelled':
      case 'notifications/roots/list_changed':
      case 'initialized':
        return null;

      case 'ping':
      case 'logging/setLevel':
        return this.makeResultResponse(id, {});

      case 'tools/list': {
        const policy = this.currentPolicy();
        if (!externalAgentAllowsRead(policy, channel)) {
          return this.makeErrorResponse(id, -32001, disabledMessage);
        }
        return this.makeResultResponse(id, { tools: mcpToolDefinitions() });
      }

      case 'tools/call': {
        const name = asString(params.name);
        if (!name) {
          return this.makeErrorResponse(id, -32602, 'Invalid params: missing tool name');
        }
        const args =
          params.arguments && typeof params.arguments === 'object' && !Array.isArray(params.arguments)
            ? (params.arguments as Record<string, unknown>)
            : {};
        const output = await this.callTool(name, args, channel);
        return this.makeResultResponse(id, {
          content: output.content,
          isError: output.isError,
        });
      }

      case 'resources/list': {
        const policy = this.currentPolicy();
        if (!externalAgentAllowsRead(policy, channel)) {
          return this.makeErrorResponse(id, -32001, disabledMessage);
        }
        return this.makeResultResponse(id, { resources: mcpResourceDefinitions() });
      }

      case 'resources/templates/list': {
        const policy = this.currentPolicy();
        if (!externalAgentAllowsRead(policy, channel)) {
          return this.makeErrorResponse(id, -32001, disabledMessage);
        }
        return this.makeResultResponse(id, {
          resourceTemplates: mcpResourceTemplateDefinitions(),
        });
      }

      case 'resources/read': {
        const uri = asString(params.uri);
        if (!uri) {
          return this.makeErrorResponse(id, -32602, 'Missing resource uri');
        }
        const policy = this.currentPolicy();
        if (!externalAgentAllowsRead(policy, channel)) {
          return this.makeErrorResponse(id, -32001, disabledMessage);
        }
        return this.handleReadResource(uri, id, channel);
      }

      case 'prompts/list': {
        const policy = this.currentPolicy();
        if (!externalAgentAllowsRead(policy, channel)) {
          return this.makeErrorResponse(id, -32001, disabledMessage);
        }
        return this.makeResultResponse(id, { prompts: mcpPromptDefinitions() });
      }

      case 'prompts/get': {
        const policy = this.currentPolicy();
        if (!externalAgentAllowsRead(policy, channel)) {
          return this.makeErrorResponse(id, -32001, disabledMessage);
        }
        const name = asString(params.name);
        if (!name) {
          return this.makeErrorResponse(id, -32602, 'Invalid params: missing prompt name');
        }
        const promptArgs =
          params.arguments && typeof params.arguments === 'object' && !Array.isArray(params.arguments)
            ? (params.arguments as Record<string, unknown>)
            : {};
        const rendered = renderPrompt(name, promptArgs);
        if (!rendered) {
          return this.makeErrorResponse(id, -32602, `Unknown prompt: ${name}`);
        }
        return this.makeResultResponse(id, rendered);
      }

      default:
        if (isNotification) return null;
        return this.makeErrorResponse(id, -32601, `Method not found: ${method}`);
    }
  }

  private async handleReadResource(
    uri: string,
    id: unknown,
    channel: ExternalAgentChannel,
  ): Promise<Record<string, unknown>> {
    const wrapOutput = (out: MCPToolOutput): Record<string, unknown> => {
      const text = extractTextFromToolOutput(out);
      if (out.isError) {
        return this.makeErrorResponse(id, -32002, text || `Failed to read resource: ${uri}`);
      }
      return this.makeResultResponse(id, {
        contents: [{ uri, mimeType: 'application/json', text }],
      });
    };

    if (uri === 'charkle://library/overview') {
      return wrapOutput(await this.callTool('library_overview', {}, channel));
    }
    if (uri === 'charkle://boards') {
      return wrapOutput(await this.callTool('list_boards', {}, channel));
    }
    if (uri === 'charkle://folders') {
      try {
        const folders = this.deps.db.fetchFolders();
        const paths = buildFolderPathsMap(folders);
        const items = flattenFolderTree(folders).map((node) => ({
          id: node.folder.id,
          name: node.folder.name,
          path: paths.get(node.folder.id) ?? node.folder.name,
          parentID: node.folder.parentID ?? '',
          depth: node.depth,
          assetCount: node.folder.assetCount,
          colorHex: node.folder.colorHex ?? '',
          customSymbol: node.folder.customSymbol ?? '',
        }));
        return wrapOutput(jsonToolOutput({ count: items.length, folders: items }));
      } catch (err) {
        return this.makeErrorResponse(id, -32603, err instanceof Error ? err.message : String(err));
      }
    }
    if (uri === 'charkle://smart-folders') {
      try {
        const smartFolders = this.deps.db.fetchSmartFolders();
        const activeAssets = this.deps.db.fetchAssets({ includeTrashed: false });
        const items = smartFolders.map((sf) => ({
          id: sf.id,
          name: sf.name,
          colorHex: sf.colorHex ?? '',
          matchMode: sf.rule.matchMode,
          tags: sf.rule.tags,
          descriptionQuery: sf.rule.descriptionQuery,
          colorHexes: sf.rule.colorHexes,
          mediaKinds: sf.rule.mediaKinds,
          minRating: sf.rule.minRating,
          matchCount: activeAssets.filter((a) => matchesSmartFolderRule(sf.rule, a)).length,
        }));
        return wrapOutput(jsonToolOutput({ count: items.length, smartFolders: items }));
      } catch (err) {
        return this.makeErrorResponse(id, -32603, err instanceof Error ? err.message : String(err));
      }
    }
    if (uri.startsWith('charkle://assets/')) {
      const assetID = uri.slice('charkle://assets/'.length);
      return wrapOutput(await this.callTool('get_asset', { asset_id: assetID }, channel));
    }
    if (uri.startsWith('charkle://boards/')) {
      const boardID = uri.slice('charkle://boards/'.length);
      return wrapOutput(await this.callTool('get_board_context', { board_id: boardID }, channel));
    }
    return this.makeErrorResponse(id, -32002, `Unknown resource URI: ${uri}`);
  }

  // MARK: - Tool Dispatcher & Policy Enforcement

  async callTool(
    name: string,
    args: Record<string, unknown> = {},
    channel: ExternalAgentChannel = 'mcp',
  ): Promise<MCPToolOutput> {
    const policy = this.currentPolicy();
    if (!externalAgentAllowsRead(policy, channel)) {
      return errorToolOutput(
        channel === 'cli'
          ? 'CLI 命令行服务已在 Charkle「设置 → 外部 Agent 与 MCP」中关闭，请先开启「启用本地命令行 (stdio) 服务」后再试。'
          : 'MCP 服务已在 Charkle「设置 → 外部 Agent 与 MCP」中关闭，请先开启「启用 MCP 服务」后再试。',
      );
    }
    if (MCP_WRITE_TOOL_NAMES.has(name) && !externalAgentAllowsWrite(policy, channel)) {
      return errorToolOutput(
        `当前 Charkle 外部 Agent 权限为「仅只读检索与导出」，无法执行写入操作「${name}」。请在 Charkle「设置 → 外部 Agent 与 MCP」中切换为「允许整理与生成情绪板」。`,
      );
    }

    try {
      switch (name) {
        // 12 Read Tools
        case 'library_overview':
          return await this.handleLibraryOverview(policy, channel);
        case 'search_assets':
          return this.handleSearchAssets(args);
        case 'list_inbox':
          return this.handleListInbox(args);
        case 'get_asset':
          return await this.handleGetAsset(args);
        case 'render_contact_sheet':
          return await this.handleRenderContactSheet(args);
        case 'find_similar_assets':
          return await this.handleFindSimilarAssets(args);
        case 'semantic_search':
          return await this.handleSemanticSearch(args);
        case 'quick_jump':
          return this.handleQuickJump(args);
        case 'suggest_folder':
          return this.handleSuggestFolder(args);
        case 'list_boards':
          return this.handleListBoards();
        case 'get_board_context':
          return this.handleGetBoardContext(args);
        case 'export_board_image':
          return await this.handleExportBoardImage(args);

        // 8 Safe Write Tools (Zero Permanent Delete)
        case 'organize_assets':
          return this.handleOrganizeAssets(args);
        case 'create_folder':
          return this.handleCreateFolder(args);
        case 'update_folder':
          return this.handleUpdateFolder(args);
        case 'ingest_asset':
          return await this.handleIngestAsset(args);
        case 'compose_moodboard':
          return await this.handleComposeMoodboard(args);
        case 'patch_moodboard':
          return this.handlePatchMoodboard(args);
        case 'trash_assets':
          return this.handleTrashAssets(args);
        case 'analyze_assets':
          return await this.handleAnalyzeAssets(args);

        default:
          return errorToolOutput(`Unknown Charkle tool: ${name}`);
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return errorToolOutput(`Tool ${name} failed: ${msg}`);
    }
  }

  // MARK: - 12 Read Tool Handlers

  private async handleLibraryOverview(
    policy: ExternalAgentConfig,
    channel: ExternalAgentChannel,
  ): Promise<MCPToolOutput> {
    const overview = this.tools.libraryOverview();
    const trashedCount = this.deps.db.trashCount();
    const smartFolders = this.deps.db.fetchSmartFolders();
    let untaggedCount: number;
    let smartFolderPayloads: Array<Record<string, unknown>>;

    if (smartFolders.length === 0) {
      untaggedCount = this.deps.db.untaggedCount();
      smartFolderPayloads = [];
    } else {
      const activeAssets = this.deps.db.fetchAssets({ includeTrashed: false });
      untaggedCount = activeAssets.filter((a) => a.tags.length === 0).length;
      smartFolderPayloads = smartFolders.map((sf) => ({
        id: sf.id,
        name: sf.name,
        colorHex: sf.colorHex ?? '',
        matchCount: activeAssets.filter((a) => matchesSmartFolderRule(sf.rule, a)).length,
      }));
    }

    const foldersRaw = this.deps.db.fetchFolders();
    const folderByID = new Map(foldersRaw.map((f) => [f.id, f]));
    const syncCfg = this.deps.configStore.getSyncConfig();
    const aiCfg = this.deps.configStore.getAIConfig();
    const cache = await this.deps.media.getCacheStats(this.deps.db);

    return jsonToolOutput({
      totalAssets: overview.totalAssets,
      inboxCount: overview.inboxCount,
      untaggedCount,
      trashedCount,
      boardCount: overview.boardCount,
      mcpEnabled: policy.mcpEnabled,
      cliEnabled: policy.cliEnabled,
      accessLevel: policy.accessLevel,
      canWrite: externalAgentAllowsWrite(policy, channel),
      syncMode: syncCfg.mode,
      aiConfigured: aiCfg.provider !== 'disabled',
      mediaKindCounts: overview.mediaKindCounts,
      folders: overview.folders.map((folder) => {
        const raw = folderByID.get(folder.id);
        return {
          id: folder.id,
          name: folder.name,
          path: folder.path,
          parentID: raw?.parentID ?? '',
          assetCount: folder.assetCount,
          colorHex: raw?.colorHex ?? '',
          customSymbol: raw?.customSymbol ?? '',
        };
      }),
      smartFolders: smartFolderPayloads,
      topTags: overview.topTags.slice(0, 40),
      cache,
    });
  }

  private handleSearchAssets(args: Record<string, unknown>): MCPToolOutput {
    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const criteria = this.buildFilterCriteria(args, folders, folderPathByID);
    const smartFolder = this.resolveOptionalSmartFolder(args);
    const offset = Math.max(0, asInt(args.offset) ?? 0);
    const limit = Math.max(1, Math.min(100, asInt(args.limit) ?? 30));

    let matches = this.deps.db.fetchAssets(criteria);
    if (smartFolder) {
      matches = matches.filter((a) => matchesSmartFolderRule(smartFolder.rule, a));
    }
    const sliced = paginate(matches, offset, limit);
    const hasMore = offset + sliced.length < matches.length;

    const payload: Record<string, unknown> = {
      totalMatched: matches.length,
      offset,
      returned: sliced.length,
      hasMore,
      assets: sliced.map((a) => this.serializeAssetSummary(a, folderPathByID)),
    };
    if (hasMore) payload.nextOffset = offset + sliced.length;
    if (smartFolder) payload.smartFolder = { id: smartFolder.id, name: smartFolder.name };
    return jsonToolOutput(payload);
  }

  private handleListInbox(args: Record<string, unknown>): MCPToolOutput {
    const offset = Math.max(0, asInt(args.offset) ?? 0);
    const limit = Math.max(1, Math.min(100, asInt(args.limit) ?? 40));
    const sortBy = parseSortOrder(args.sort_by, 'newest');
    const kinds = parseMediaKinds(args.media_kinds);

    const matches = this.deps.db.fetchAssets({ kinds, onlyInbox: true, sortBy });
    const sliced = paginate(matches, offset, limit);
    const hasMore = offset + sliced.length < matches.length;

    const payload: Record<string, unknown> = {
      inboxTotal: matches.length,
      offset,
      returned: sliced.length,
      hasMore,
      assets: sliced.map((a) => this.serializeAssetSummary(a, new Map())),
    };
    if (hasMore) payload.nextOffset = offset + sliced.length;
    return jsonToolOutput(payload);
  }

  private async handleGetAsset(args: Record<string, unknown>): Promise<MCPToolOutput> {
    const assetID = parseUUID(args.asset_id ?? args.id);
    if (!assetID) {
      return errorToolOutput('Missing or invalid UUID for `asset_id`.');
    }
    let asset = this.deps.db.getAsset(assetID);
    if (!asset) {
      return errorToolOutput(`Asset not found: ${assetID}`);
    }

    // Lazily hydrate camera EXIF / AI generation prompt metadata if not yet populated
    const hydrated = await this.deps.media.hydrateImageMetadata(asset).catch(() => null);
    if (hydrated) {
      asset = this.deps.db.saveAssetLocally(hydrated, false);
    }

    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const thumbPath = this.deps.media.getThumbnailPath(assetID, 'grid520') ?? '';
    const previewPath = this.deps.media.getThumbnailPath(assetID, 'preview1400') ?? '';
    const origPath = this.deps.media.getOriginalPath(asset) ?? '';
    const hasOrig = origPath ? true : await this.deps.media.hasOriginal(asset);

    const dict: Record<string, unknown> = {
      ...this.serializeAssetSummary(asset, folderPathByID),
      mimeType: asset.mimeType,
      displayType: getAssetDisplayTypeLabel(asset),
      aspectShape: getAssetAspectShape(asset),
      ocrText: asset.ocrText ?? '',
      suggestedTags: asset.suggestedTags,
      sourceDomain: asset.sourceDomain ?? '',
      fileSizeBytes: asset.fileSizeBytes,
      pixelWidth: asset.pixelWidth,
      pixelHeight: asset.pixelHeight,
      pinnedOffline: asset.pinnedOffline,
      isLocalOriginalCached: hasOrig,
      thumbnailPath: thumbPath,
      previewPath,
      localOriginalPath: origPath,
      isTrashed: asset.isTrashed,
      createdAt: asset.createdAt,
      updatedAt: asset.updatedAt,
    };
    if (asset.durationSeconds != null) {
      dict.durationSeconds = Math.round(asset.durationSeconds * 100) / 100;
    }
    if (asset.lastOpenedAt) {
      dict.lastOpenedAt = asset.lastOpenedAt;
    }
    const rich = this.serializeRichMetadata(asset.richMetadata);
    if (rich) {
      dict.richMetadata = rich;
    }

    const includeImage = asBool(args.include_image) ?? false;
    if (includeImage) {
      const maxSide = Math.max(280, Math.min(1568, asInt(args.image_max_side) ?? 800));
      const rawBuf =
        (await this.deps.media.readThumbnailBuffer(assetID, 'preview1400')) ??
        (await this.deps.media.readThumbnailBuffer(assetID, 'grid520')) ??
        (await this.deps.media.readOriginalBuffer(asset));
      if (rawBuf && rawBuf.byteLength > 0) {
        let imgData: Uint8Array = rawBuf;
        let imgMime = sniffImageMimeType(rawBuf, 'image/jpeg');
        if (this.deps.media.images.cropAndPad) {
          const prepared = await this.deps.media.images
            .cropAndPad(rawBuf, { targetLongSide: maxSide, maxSide: 1568, quality: 0.86 })
            .catch(() => null);
          if (prepared) {
            imgData = prepared.data;
            imgMime = prepared.mimeType;
          }
        }
        return {
          content: [
            { type: 'image', mimeType: imgMime, data: bytesToBase64(imgData) },
            { type: 'text', text: JSON.stringify(dict, null, 2) },
          ],
          isError: false,
        };
      }
    }

    return jsonToolOutput(dict);
  }

  private async handleRenderContactSheet(args: Record<string, unknown>): Promise<MCPToolOutput> {
    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const offset = Math.max(0, asInt(args.offset) ?? 0);
    const limit = Math.max(1, Math.min(16, asInt(args.limit) ?? 16));
    const maxWidth = Math.max(640, Math.min(1920, asInt(args.max_width) ?? 1280));
    const includeImage = asBool(args.include_image) ?? true;

    let totalMatched = 0;
    let selectedAssets: AssetRecord[] = [];
    const rawIDs = parseUUIDList(args.asset_ids);
    if (rawIDs.length > 0) {
      const resolved: AssetRecord[] = [];
      for (const id of rawIDs) {
        const asset = this.deps.db.getAsset(id);
        if (asset) resolved.push(asset);
      }
      totalMatched = resolved.length;
      selectedAssets = paginate(resolved, offset, limit);
    } else {
      const criteria = this.buildFilterCriteria(args, folders, folderPathByID);
      const smartFolder = this.resolveOptionalSmartFolder(args);
      let matches = this.deps.db.fetchAssets(criteria);
      if (smartFolder) {
        matches = matches.filter((a) => matchesSmartFolderRule(smartFolder.rule, a));
      }
      totalMatched = matches.length;
      selectedAssets = paginate(matches, offset, limit);
    }

    if (selectedAssets.length === 0) {
      return jsonToolOutput({
        totalMatched,
        offset,
        slotCount: 0,
        hasMore: false,
        slots: [],
        message: 'No assets matched the requested filter or asset_ids.',
      });
    }

    const pkg = await this.tools.buildContactSheets({
      candidates: selectedAssets,
      folderPathByID,
      sheetCapacity: 16,
      maxCanvasWidth: maxWidth,
      format: 'jpeg',
    });
    const sheet = pkg.sheets[0];
    if (!sheet) {
      return errorToolOutput('Failed to render Contact Sheet image.');
    }

    let savedPath: string | undefined;
    const outPath = asTrimmedString(args.output_path);
    if (outPath) {
      if (!this.deps.localFs) {
        return errorToolOutput('`output_path` local disk writing is not supported in cloud runtime.');
      }
      const resolved = this.deps.localFs.resolvePath(outPath);
      this.deps.localFs.writeFileSync(resolved, sheet.jpegData);
      savedPath = resolved;
    }

    const slots = sheet.orderedSlots
      .map((pair) => {
        const asset = pkg.slotToAsset.get(pair.slot);
        if (!asset) return null;
        return {
          slot: pair.slot,
          index: offset + pair.slot,
          badge: `#${String(pair.slot).padStart(2, '0')}`,
          assetID: asset.id,
          title: asset.title,
          mediaKind: asset.mediaKind,
          folderPath: (asset.folderID && folderPathByID.get(asset.folderID)) || 'Inbox',
          tags: asset.tags,
          dominantColors: asset.dominantColors.slice(0, 4).map((c) => c.hex.toUpperCase()),
          aiDescription: asset.aiDescription ?? '',
        };
      })
      .filter(Boolean);

    const hasMore = offset + slots.length < totalMatched;
    const metadata: Record<string, unknown> = {
      sheetWidth: sheet.width,
      sheetHeight: sheet.height,
      totalMatched,
      offset,
      slotCount: slots.length,
      hasMore,
      slots,
    };
    if (hasMore) metadata.nextOffset = offset + slots.length;
    if (savedPath) metadata.savedPath = savedPath;

    const content: MCPToolContent[] = [];
    if (includeImage) {
      content.push({ type: 'image', mimeType: sheet.mimeType, data: bytesToBase64(sheet.jpegData) });
    }
    content.push({ type: 'text', text: JSON.stringify(metadata, null, 2) });
    return { content, isError: false };
  }

  private async handleFindSimilarAssets(args: Record<string, unknown>): Promise<MCPToolOutput> {
    const assetID = parseUUID(args.asset_id ?? args.id);
    if (!assetID) {
      return errorToolOutput('Missing or invalid UUID for `asset_id`.');
    }
    if (!this.deps.db.getAsset(assetID)) {
      return errorToolOutput(`Asset not found: ${assetID}`);
    }
    const limit = Math.max(1, Math.min(32, asInt(args.limit) ?? 12));
    const matches = this.deps.db.similarAssets(assetID, limit);
    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);

    const items = matches.map((scored, idx) => ({
      ...this.serializeAssetSummary(scored.asset, folderPathByID),
      rank: idx + 1,
      score: Math.round(scored.score * 1000) / 1000,
      matchReasons: scored.matchReasons,
    }));

    const payload = {
      referenceAssetID: assetID,
      returned: items.length,
      matches: items,
    };

    const wantSheet = asBool(args.render_contact_sheet) ?? false;
    if (wantSheet && matches.length > 0) {
      const pkg = await this.tools.buildContactSheets({
        candidates: matches.slice(0, 16).map((m) => m.asset),
        folderPathByID,
        sheetCapacity: 16,
        format: 'jpeg',
      });
      const sheet = pkg.sheets[0];
      if (sheet) {
        return {
          content: [
            { type: 'image', mimeType: sheet.mimeType, data: bytesToBase64(sheet.jpegData) },
            { type: 'text', text: JSON.stringify(payload, null, 2) },
          ],
          isError: false,
        };
      }
    }

    return jsonToolOutput(payload);
  }

  private async handleSemanticSearch(args: Record<string, unknown>): Promise<MCPToolOutput> {
    const query = asTrimmedString(args.query);
    if (!query) {
      return errorToolOutput('Missing non-empty `query` for semantic_search.');
    }
    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const criteria = this.buildFilterCriteria(args, folders, folderPathByID);
    criteria.searchQuery = '';
    const limit = Math.max(1, Math.min(50, asInt(args.limit) ?? 20));

    const report = await this.groundingService.semanticSearch(query, criteria, limit);
    const hits = report.hits.map((hit, idx) => {
      const dict: Record<string, unknown> = {
        ...this.serializeAssetSummary(hit.asset, folderPathByID),
        rank: idx + 1,
        score: Math.round(hit.score * 1000) / 1000,
        reason: hit.reason,
        source: hit.sourceLabel,
      };
      if (hit.confidence != null) {
        dict.confidence = Math.round(hit.confidence * 1000) / 1000;
      }
      return dict;
    });

    return jsonToolOutput({
      query: report.query,
      summary: report.summary,
      usedCloudEmbedding: report.usedCloudEmbedding,
      usedVisualRerank: report.usedTypeSafeJev,
      evaluatedVisualCount: report.evaluatedVisualCount,
      returned: hits.length,
      hits,
    });
  }

  private handleQuickJump(args: Record<string, unknown>): MCPToolOutput {
    const query = asTrimmedString(args.query);
    if (!query) {
      return errorToolOutput('Missing non-empty `query` for quick_jump.');
    }
    const limit = Math.max(1, Math.min(50, asInt(args.limit) ?? 20));
    const matches = this.deps.db.quickJump(query, limit);
    const items = matches.map((match) => {
      const dict: Record<string, unknown> = {
        kind: match.kind,
        title: match.title,
        subtitle: match.subtitle,
        score: Math.round(match.score * 1000) / 1000,
      };
      if (match.targetUUID) dict.targetUUID = match.targetUUID;
      if (match.tagName) dict.tagName = match.tagName;
      return dict;
    });
    return jsonToolOutput({
      query,
      returned: items.length,
      matches: items,
    });
  }

  private handleSuggestFolder(args: Record<string, unknown>): MCPToolOutput {
    const ids = parseUUIDList(args.asset_ids);
    const single = parseUUID(args.asset_id ?? args.id);
    if (single && !ids.includes(single)) {
      ids.unshift(single);
    }
    if (ids.length === 0) {
      return errorToolOutput('Provide `asset_id` or a non-empty `asset_ids` array.');
    }

    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const recommendations: Array<Record<string, unknown>> = [];

    for (const uuid of ids.slice(0, 20)) {
      const asset = this.deps.db.getAsset(uuid);
      if (!asset) {
        recommendations.push({ assetID: uuid, found: false });
        continue;
      }
      const currentFolderPath = (asset.folderID && folderPathByID.get(asset.folderID)) || 'Inbox';
      const suggestion = this.deps.db.suggestFolder(uuid);
      if (suggestion) {
        recommendations.push({
          assetID: uuid,
          assetTitle: asset.title,
          currentFolderPath,
          suggestedFolderID: suggestion.folderID,
          suggestedFolderName: suggestion.folderName,
          suggestedFolderPath: folderPathByID.get(suggestion.folderID) ?? suggestion.folderName,
          confidence: Math.round(suggestion.confidence * 1000) / 1000,
          reason: suggestion.reason,
        });
      } else {
        recommendations.push({
          assetID: uuid,
          assetTitle: asset.title,
          currentFolderPath,
          suggestedFolderID: '',
          reason: 'No confident folder match found.',
        });
      }
    }

    return jsonToolOutput({
      evaluatedCount: recommendations.length,
      recommendations,
    });
  }

  private handleListBoards(): MCPToolOutput {
    const boards = this.deps.db.fetchBoardSummaries();
    return jsonToolOutput({
      count: boards.length,
      boards: boards.map((b) => ({
        id: b.id,
        title: b.title,
        subtitle: b.subtitle,
        mode: layoutModeLabel(b.mode),
        itemCount: b.itemCount,
        paletteHexes: b.paletteHexes.map((h) => h.toUpperCase()),
        pinnedOffline: b.pinnedOffline,
        updatedAt: b.updatedAt,
      })),
    });
  }

  private handleGetBoardContext(args: Record<string, unknown>): MCPToolOutput {
    const doc = this.resolveBoard(args);
    if (!doc) {
      return errorToolOutput('Moodboard not found. Pass a valid `board_id` UUID or matching `title`.');
    }
    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const refIDs = getBoardReferencedAssetIDs(doc);
    const allAssetIDs = new Set<UUID>([...refIDs, ...doc.candidateAssetIDs]);
    const assetsByID = new Map<UUID, AssetRecord>();
    for (const id of allAssetIDs) {
      const a = this.deps.db.getAsset(id);
      if (a) assetsByID.set(id, a);
    }

    const notes: Array<Record<string, unknown>> = [];
    const sections: Array<Record<string, unknown>> = [];
    const cardRefs: Array<Record<string, unknown>> = [];

    const sortedNodes = [...doc.nodes].sort((a, b) => a.editorialOrder - b.editorialOrder);
    for (const node of sortedNodes) {
      if (node.kind.type === 'note') {
        notes.push({
          nodeID: node.id,
          title: node.kind.title ?? '',
          text: node.kind.text,
          style: node.kind.style,
          isLocked: node.isLocked,
          frame: frameDict(node.frame),
        });
      } else if (node.kind.type === 'groupFrame') {
        sections.push({
          nodeID: node.id,
          title: node.kind.title,
          tint: node.kind.tint,
          isLocked: node.isLocked,
          frame: frameDict(node.frame),
        });
      } else if (node.kind.type === 'assetRef') {
        const asset = assetsByID.get(node.kind.assetID);
        if (!asset) continue;
        const summary: Record<string, unknown> = {
          ...this.serializeAssetSummary(asset, folderPathByID),
          nodeID: node.id,
          weight: node.kind.weight,
          isHero: node.kind.weight >= 2,
          isLocked: node.isLocked,
          frame: frameDict(node.frame),
        };
        if (node.kind.crop && isMeaningfulCropSubregion(node.kind.crop)) {
          summary.crop = {
            x: Math.round(node.kind.crop.x * 1000) / 1000,
            y: Math.round(node.kind.crop.y * 1000) / 1000,
            width: Math.round(node.kind.crop.width * 1000) / 1000,
            height: Math.round(node.kind.crop.height * 1000) / 1000,
          };
        }
        const origPath = this.deps.media.getOriginalPath(asset);
        if (origPath) summary.localOriginalPath = origPath;
        cardRefs.push(summary);
      }
    }

    const connectors = doc.connectors.map((c) => ({
      id: c.id,
      fromNodeID: c.fromNodeID,
      toNodeID: c.toNodeID,
      label: c.label ?? '',
      style: c.style,
      colorHex: c.colorHex.toUpperCase(),
      dashed: c.dashed,
    }));

    const candidatePool = doc.candidateAssetIDs
      .map((cid) => {
        const asset = assetsByID.get(cid);
        if (!asset) return null;
        return {
          id: asset.id,
          title: asset.title,
          folderPath: (asset.folderID && folderPathByID.get(asset.folderID)) || 'Inbox',
        };
      })
      .filter(Boolean);

    const palette = doc.extractedPalette.map((c) => ({
      hex: c.hex.toUpperCase(),
      proportion: Math.round(c.proportion * 1000) / 1000,
      lab: { l: Math.round(c.l), a: Math.round(c.a), b: Math.round(c.b) },
    }));

    return jsonToolOutput({
      id: doc.id,
      title: doc.title,
      subtitle: doc.subtitle,
      mode: layoutModeLabel(doc.mode),
      pinnedOffline: doc.pinnedOffline,
      updatedAt: doc.updatedAt,
      itemCount: cardRefs.length,
      inkStrokeCount: doc.inkStrokes.length,
      palette,
      notes,
      sections,
      connectors,
      assets: cardRefs,
      candidatePool,
    });
  }

  private async handleExportBoardImage(args: Record<string, unknown>): Promise<MCPToolOutput> {
    const doc = this.resolveBoard(args);
    if (!doc) {
      return errorToolOutput('Moodboard not found. Pass a valid `board_id` UUID or matching `title`.');
    }
    const refIDs = getBoardReferencedAssetIDs(doc);
    const assetsByID = new Map<UUID, AssetRecord>();
    for (const id of refIDs) {
      const a = this.deps.db.getAsset(id);
      if (a) assetsByID.set(id, a);
    }

    const dark = asBool(args.dark_appearance) ?? false;
    const width = Math.max(640, Math.min(2800, asInt(args.width) ?? 1440));
    const includeImage = asBool(args.include_image) ?? true;
    if (!this.deps.media.images.exportMoodboardImage) {
      return errorToolOutput('Moodboard image export is not available on this runtime.');
    }

    const rendered = await this.deps.media.images.exportMoodboardImage({
      document: doc,
      assetsByID,
      loadAssetBytes: async (assetID) =>
        (await this.deps.media.readThumbnailBuffer(assetID, 'preview1400')) ??
        (await this.deps.media.readThumbnailBuffer(assetID, 'grid520')),
      format: 'png',
      containerWidth: width,
      options: {
        scale: 1,
        darkAppearance: dark,
        includeAnnotations: true,
        includePaletteStrip: true,
        padding: 40,
      },
    });

    const metadata: Record<string, unknown> = {
      boardID: doc.id,
      title: doc.title,
      itemCount: refIDs.length,
      width,
      darkAppearance: dark,
      bytes: rendered.data.byteLength,
      mimeType: rendered.mimeType,
    };

    const outPath = asTrimmedString(args.output_path);
    if (outPath) {
      if (!this.deps.localFs) {
        return errorToolOutput('`output_path` local disk writing is not supported in cloud runtime.');
      }
      const resolved = this.deps.localFs.resolvePath(outPath);
      this.deps.localFs.writeFileSync(resolved, rendered.data);
      metadata.savedPath = resolved;
    }

    const content: MCPToolContent[] = [];
    if (includeImage) {
      content.push({ type: 'image', mimeType: rendered.mimeType, data: bytesToBase64(rendered.data) });
    }
    content.push({ type: 'text', text: JSON.stringify(metadata, null, 2) });
    return { content, isError: false };
  }

  // MARK: - 8 Safe Write Tool Handlers (Never Permanent Delete)

  private handleOrganizeAssets(args: Record<string, unknown>): MCPToolOutput {
    const ids = parseUUIDList(args.asset_ids);
    if (ids.length === 0) {
      return errorToolOutput('`asset_ids` must be a non-empty array of asset UUID strings.');
    }

    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);

    let folderAssignment: FolderAssignment = { type: 'unchanged' };
    if (asBool(args.move_to_inbox) === true) {
      folderAssignment = { type: 'inbox' };
    } else {
      const resolvedFolderID = this.resolveOptionalFolderID(args, folders, folderPathByID);
      if (resolvedFolderID) {
        folderAssignment = { type: 'folder', folderID: resolvedFolderID };
      }
    }

    const patch = createDefaultAssetBatchPatch(ids, {
      title: asString(args.title),
      notes: asString(args.notes),
      rating: asInt(args.rating),
      addTags: asStringArray(args.add_tags) ?? [],
      removeTags: asStringArray(args.remove_tags) ?? [],
      acceptSuggestedTags: asBool(args.accept_suggested_tags) ?? false,
      dismissSuggestedTags: asStringArray(args.dismiss_suggested_tags) ?? [],
      folderAssignment,
      pinnedOffline: asBool(args.pinned_offline),
    });

    const updated = this.deps.db.applyBatchPatch(patch);
    const updatedSet = new Set(updated.map((a) => a.id));
    const skippedIDs = ids.filter((id) => !updatedSet.has(id));

    // Explicit overwrite when external agent passes `ai_description`
    const aiDesc = asTrimmedString(args.ai_description);
    if (aiDesc && updated.length > 0) {
      this.tools.persistVisualInsights(
        updated.map((a) => ({ assetID: a.id, description: aiDesc, tags: [] })),
        true,
      );
    }

    if (updated.length > 0) {
      this.deps.events.emitLibraryChanged(
        'mcp.organize_assets',
        updated.map((a) => a.id),
      );
    }

    const result: Record<string, unknown> = {
      updatedCount: updated.length,
      assetIDs: updated.map((a) => a.id),
    };
    if (skippedIDs.length > 0) result.skippedIDs = skippedIDs;
    return jsonToolOutput(result);
  }

  private handleCreateFolder(args: Record<string, unknown>): MCPToolOutput {
    const name = asTrimmedString(args.name);
    if (!name) {
      return errorToolOutput('Missing non-empty folder `name`.');
    }
    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const parentID = this.resolveOptionalFolderID(
      { folder_id: args.parent_id, folder_path: args.parent_path },
      folders,
      folderPathByID,
    );
    let created = this.deps.db.createFolder(name, parentID);

    const hasColor = 'color_hex' in args && args.color_hex !== undefined;
    const hasSymbol = 'custom_symbol' in args && args.custom_symbol !== undefined;
    if (hasColor || hasSymbol) {
      created = this.deps.db.updateFolderAppearance(created.id, {
        ...(hasColor ? { colorHex: asTrimmedString(args.color_hex) } : {}),
        ...(hasSymbol ? { customSymbol: asTrimmedString(args.custom_symbol) } : {}),
      });
    }

    const refreshedPaths = buildFolderPathsMap(this.deps.db.fetchFolders());
    this.deps.events.emitLibraryChanged('mcp.create_folder', undefined, [created.id]);

    return jsonToolOutput({
      id: created.id,
      name: created.name,
      path: refreshedPaths.get(created.id) ?? created.name,
      parentID: created.parentID ?? '',
      colorHex: created.colorHex ?? '',
      customSymbol: created.customSymbol ?? '',
    });
  }

  private handleUpdateFolder(args: Record<string, unknown>): MCPToolOutput {
    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const folderID = this.resolveOptionalFolderID(args, folders, folderPathByID);
    let current = folderID ? folders.find((f) => f.id === folderID) ?? null : null;
    if (!folderID || !current) {
      return errorToolOutput(
        'Folder not found. Pass a valid `folder_id` UUID or matching `folder_path`.',
      );
    }

    const newName = asTrimmedString(args.new_name);
    if (newName) {
      current = this.deps.db.renameFolder(folderID, newName);
    }

    const moveToRoot = asBool(args.move_to_root) ?? false;
    const hasParentArg =
      Boolean(asTrimmedString(args.parent_id)) || Boolean(asTrimmedString(args.parent_path));
    if (moveToRoot || hasParentArg) {
      const latestFolders = this.deps.db.fetchFolders();
      const latestPaths = buildFolderPathsMap(latestFolders);
      const newParentID = moveToRoot
        ? null
        : this.resolveOptionalFolderID(
            { folder_id: args.parent_id, folder_path: args.parent_path },
            latestFolders,
            latestPaths,
          );
      this.deps.db.moveFolder(folderID, newParentID, null);
    }

    const hasColor = 'color_hex' in args && args.color_hex !== undefined;
    const hasSymbol = 'custom_symbol' in args && args.custom_symbol !== undefined;
    if (hasColor || hasSymbol) {
      current = this.deps.db.updateFolderAppearance(folderID, {
        ...(hasColor ? { colorHex: asTrimmedString(args.color_hex) } : {}),
        ...(hasSymbol ? { customSymbol: asTrimmedString(args.custom_symbol) } : {}),
      });
    }

    const finalFolders = this.deps.db.fetchFolders();
    const finalPaths = buildFolderPathsMap(finalFolders);
    const finalFolder = finalFolders.find((f) => f.id === folderID) ?? current;

    this.deps.events.emitLibraryChanged('mcp.update_folder', undefined, [finalFolder.id]);

    return jsonToolOutput({
      id: finalFolder.id,
      name: finalFolder.name,
      path: finalPaths.get(finalFolder.id) ?? finalFolder.name,
      parentID: finalFolder.parentID ?? '',
      colorHex: finalFolder.colorHex ?? '',
      customSymbol: finalFolder.customSymbol ?? '',
      assetCount: finalFolder.assetCount,
    });
  }

  private async handleIngestAsset(args: Record<string, unknown>): Promise<MCPToolOutput> {
    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const targetFolderID = this.resolveOptionalFolderID(args, folders, folderPathByID);

    let targetBoardID: UUID | null = null;
    const rawBoard = asTrimmedString(args.target_board_id);
    if (rawBoard) {
      targetBoardID = parseUUID(rawBoard);
      if (!targetBoardID) {
        return errorToolOutput(`Invalid \`target_board_id\` UUID: ${rawBoard}`);
      }
      if (!this.deps.db.getBoard(targetBoardID)) {
        return errorToolOutput(`Target moodboard not found: ${targetBoardID}`);
      }
    }

    const inputs: CaptureInput[] = [];
    const filePaths = asStringArray(args.file_paths)?.filter((p) => p.trim().length > 0) ?? [];
    const filePath = asTrimmedString(args.file_path);
    const webURL = asTrimmedString(args.web_url);
    const text = asTrimmedString(args.text);
    const title = asTrimmedString(args.title);
    const initialNotes = asString(args.notes);

    if (filePaths.length > 0) {
      if (!this.deps.localFs) {
        return errorToolOutput('`file_paths` local filesystem ingest is not supported in cloud runtime.');
      }
      for (const rawPath of filePaths) {
        const resolved = this.deps.localFs.resolvePath(rawPath.trim());
        if (!this.deps.localFs.existsSync(resolved)) {
          return errorToolOutput(`File not found at path: ${resolved}`);
        }
        inputs.push({ type: 'fileURL', url: resolved });
      }
    } else if (filePath) {
      if (!this.deps.localFs) {
        return errorToolOutput('`file_path` local filesystem ingest is not supported in cloud runtime.');
      }
      const resolved = this.deps.localFs.resolvePath(filePath);
      if (!this.deps.localFs.existsSync(resolved)) {
        return errorToolOutput(`File not found at path: ${resolved}`);
      }
      inputs.push({ type: 'fileURL', url: resolved });
    } else if (webURL) {
      try {
        const parsed = new URL(webURL);
        if (!parsed.protocol) throw new Error('Invalid URL');
      } catch {
        return errorToolOutput(`Invalid web_url: ${webURL}`);
      }
      inputs.push({ type: 'webURL', url: webURL, title, notes: initialNotes ?? null });
    } else if (text) {
      inputs.push({ type: 'textSnippet', title: title ?? 'Agent 笔记', text, sourceURL: null });
    } else {
      return errorToolOutput('Provide one of `file_path`, `file_paths`, `web_url`, or `text`.');
    }

    const syncCfg = this.deps.configStore.getSyncConfig();
    let finalAssets: AssetRecord[] = [];
    for (const input of inputs) {
      const ingested = await this.deps.media.ingest(input, targetFolderID);
      const saved = this.deps.db.transaction(() => {
        if (ingested.asset.contentHash) {
          this.deps.db.setState(`deleted.content.${ingested.asset.contentHash}`, null);
        }
        const persisted = this.deps.db.saveAssetLocally(ingested.asset);
        this.deps.db.touchOriginal(persisted.id);
        this.deps.db.markProjection('thumbnails', persisted.id);
        if (ingested.vector) {
          if (syncCfg.syncEmbeddings) {
            this.deps.db.recordSyncChange({
              type: 'vector',
              id: persisted.id,
              vector: ingested.vector,
            });
          } else {
            this.deps.db.saveVector(persisted.id, ingested.vector);
          }
        }
        return persisted;
      });
      finalAssets.push(saved);
    }

    const tags = asStringArray(args.tags) ?? [];
    const rating = asInt(args.rating);
    if (finalAssets.length > 0 && (tags.length > 0 || initialNotes !== null || rating !== null)) {
      const patched = this.deps.db.applyBatchPatch(
        createDefaultAssetBatchPatch(
          finalAssets.map((a) => a.id),
          {
            addTags: tags,
            notes: initialNotes,
            rating,
          },
        ),
      );
      if (patched.length > 0) finalAssets = patched;
    }

    if (targetBoardID && finalAssets.length > 0) {
      this.appendAssetsToBoard(targetBoardID, finalAssets);
    }

    const latestPaths = buildFolderPathsMap(this.deps.db.fetchFolders());
    if (finalAssets.length > 0) {
      this.deps.events.emitLibraryChanged(
        'mcp.ingest_asset',
        finalAssets.map((a) => a.id),
      );
    }

    return jsonToolOutput({
      importedCount: finalAssets.length,
      assets: finalAssets.map((a) => this.serializeAssetSummary(a, latestPaths)),
    });
  }

  private async handleComposeMoodboard(args: Record<string, unknown>): Promise<MCPToolOutput> {
    const title = asTrimmedString(args.title) ?? '';
    const subtitle = asTrimmedString(args.subtitle) ?? '';
    const layoutRaw = (asString(args.layout_style) ?? 'magazine').toLowerCase();
    const layoutStyle: EditorialStyle = (EDITORIAL_STYLES as readonly string[]).includes(layoutRaw)
      ? (layoutRaw as EditorialStyle)
      : 'magazine';
    const useFreeform =
      asBool(args.use_freeform) ?? asBool(args.useFreeformLayout) ?? true;

    const explicitSections = Array.isArray(args.sections)
      ? (args.sections.filter((s) => s && typeof s === 'object') as Array<Record<string, unknown>>)
      : [];
    const flatAssetIDs = parseUUIDList(args.asset_ids);

    // Mode A: Explicit sections or asset_ids
    if (explicitSections.length > 0 || flatAssetIDs.length > 0) {
      const orderedAssets: AssetRecord[] = [];
      const slotByAssetID = new Map<UUID, number>();
      const slotToAsset = new Map<number, AssetRecord>();

      const registerAsset = (id: UUID): number | null => {
        const existing = slotByAssetID.get(id);
        if (existing !== undefined) return existing;
        const asset = this.deps.db.getAsset(id);
        if (!asset) return null;
        const slot = orderedAssets.length + 1;
        orderedAssets.push(asset);
        slotByAssetID.set(id, slot);
        slotToAsset.set(slot, asset);
        return slot;
      };

      const sectionSpecs: AgentSectionSpec[] = [];
      if (explicitSections.length > 0) {
        for (const sec of explicitSections) {
          const secTitle = asString(sec.title) ?? '精选参考';
          const tintRaw = (asString(sec.tint) ?? 'neutral').toLowerCase();
          const tint: GroupTint = (GROUP_TINTS as readonly string[]).includes(tintRaw)
            ? (tintRaw as GroupTint)
            : 'neutral';
          const rationale = asString(sec.rationale) ?? '';
          const heroSet = new Set(parseUUIDList(sec.hero_asset_ids));
          const secIDs = parseUUIDList(sec.asset_ids);
          const picks: AgentSlotPick[] = [];
          for (const aid of secIDs) {
            const slot = registerAsset(aid);
            if (slot !== null) {
              picks.push({ slot, weight: heroSet.has(aid) ? 2 : 1, reason: rationale });
            }
          }
          if (picks.length > 0) {
            sectionSpecs.push({ title: secTitle, tint, rationale, picks });
          }
        }
      } else {
        const heroSet = new Set(parseUUIDList(args.hero_asset_ids));
        const picks: AgentSlotPick[] = [];
        flatAssetIDs.forEach((aid, idx) => {
          const slot = registerAsset(aid);
          if (slot !== null) {
            const weight = heroSet.has(aid) || (heroSet.size === 0 && idx === 0) ? 2 : 1;
            picks.push({ slot, weight, reason: '' });
          }
        });
        if (picks.length > 0) {
          sectionSpecs.push({ title: '核心视觉参考', tint: 'neutral', rationale: '', picks });
        }
      }

      if (sectionSpecs.length === 0) {
        return errorToolOutput('None of the provided `asset_ids` were found in the Charkle library.');
      }

      const noteText = asTrimmedString(args.curator_note);
      const plan: AgentBoardPlan = {
        boardTitle: title || 'Agent 策展情绪板',
        boardSubtitle: subtitle,
        curatorNote: noteText ? { title: '策展说明', text: noteText, style: 'paper' } : null,
        recommendedLayout: layoutStyle,
        sections: sectionSpecs,
        candidatePicks: [],
        rejectedNote: null,
        visualInsights: [],
      };
      const req = createDefaultMoodboardCurationRequest({
        prompt: title,
        preferredCount: Math.max(orderedAssets.length, 12),
        layoutStyle,
        useFreeformLayout: useFreeform,
        includeCuratorNotes: Boolean(noteText),
      });
      const recall: AgentRecallResult = {
        eligibleTotal: orderedAssets.length,
        candidates: orderedAssets,
        scoresByID: new Map(
          orderedAssets.map((a) => [a.id, { asset: a, score: 1.0, matchReasons: ['Agent 精选'] }]),
        ),
        folderPathByID: new Map(),
      };
      const compiled = this.tools.compileAndVerifyBoard({
        plan,
        slotToAsset,
        request: req,
        recall,
      });
      const saved = this.deps.db.saveBoardLocally(compiled.document);
      this.deps.events.emitBoardUpdated(saved.id);

      return jsonToolOutput({
        boardID: saved.id,
        title: saved.title,
        subtitle: saved.subtitle,
        mode: layoutModeLabel(saved.mode),
        itemCount: getBoardReferencedAssetIDs(saved).length,
        paletteHexes: saved.extractedPalette.map((c) => c.hex.toUpperCase()),
      });
    }

    // Mode B: Prompt-driven automatic curation
    const prompt = asTrimmedString(args.prompt) ?? title;
    if (!prompt) {
      return errorToolOutput(
        'Provide either `sections` / `asset_ids` for direct curation, or `prompt` for automatic curation.',
      );
    }

    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const scopeID = this.resolveOptionalFolderID(args, folders, folderPathByID);
    const preferredCount = Math.max(2, Math.min(24, asInt(args.preferred_count) ?? 12));
    const seedAssetIDs = parseUUIDList(args.seed_asset_ids);
    const requiredTags = asStringArray(args.required_tags) ?? [];
    const targetPalette = (asStringArray(args.target_palette) ?? []).map((hex) => labFromHex(hex));

    const req = createDefaultMoodboardCurationRequest({
      prompt,
      seedAssetIDs,
      scopeFolderIDs: scopeID ? [scopeID] : [],
      requiredTags,
      targetPalette,
      preferredCount,
      layoutStyle,
      useFreeformLayout: useFreeform,
      includeCuratorNotes: true,
    });

    let provider: CloudAIProvider | null = null;
    try {
      provider = this.deps.getCloudAIProvider?.() ?? null;
    } catch {
      provider = null;
    }

    const proposal = await this.harness.curate({
      request: req,
      provider,
      typeSafeConfig: this.deps.configStore.getTypeSafeConfig(),
      typeSafeAPIKey: this.deps.getTypeSafeAPIKey?.() ?? null,
      grounding: this.deps.grounding ?? null,
    });

    const doc: MoodboardDocument = {
      ...proposal.draftDocument,
      title: title || proposal.draftDocument.title,
      subtitle: subtitle || proposal.draftDocument.subtitle,
    };
    const saved = this.deps.db.saveBoardLocally(doc);
    this.deps.events.emitBoardUpdated(saved.id);

    return jsonToolOutput({
      boardID: saved.id,
      title: saved.title,
      subtitle: saved.subtitle,
      mode: layoutModeLabel(saved.mode),
      itemCount: getBoardReferencedAssetIDs(saved).length,
      usedCloudAI: proposal.usedCloudAI,
      curatedSummary: proposal.curatedSummary,
      paletteHexes: saved.extractedPalette.map((c) => c.hex.toUpperCase()),
    });
  }

  private handlePatchMoodboard(args: Record<string, unknown>): MCPToolOutput {
    const existingDoc = this.resolveBoard(args);
    if (!existingDoc) {
      return errorToolOutput('Moodboard not found. Pass a valid `board_id` UUID or matching `title`.');
    }

    const doc: MoodboardDocument = {
      ...existingDoc,
      nodes: [...existingDoc.nodes],
      connectors: [...existingDoc.connectors],
    };

    const newTitle = asTrimmedString(args.new_title);
    if (newTitle) doc.title = newTitle;
    if (typeof args.subtitle === 'string') doc.subtitle = args.subtitle.trim();

    const useFreeformArg = asBool(args.use_freeform);
    const styleRaw = asTrimmedString(args.layout_style)?.toLowerCase();
    const validStyle: EditorialStyle | null =
      styleRaw && (EDITORIAL_STYLES as readonly string[]).includes(styleRaw)
        ? (styleRaw as EditorialStyle)
        : null;

    if (useFreeformArg !== null) {
      if (useFreeformArg) {
        doc.mode = { type: 'freeform' };
      } else {
        doc.mode = {
          type: 'autoEditorial',
          config: createDefaultAutoLayoutConfig({ style: validStyle ?? 'magazine' }),
        };
      }
    } else if (validStyle && doc.mode.type === 'autoEditorial') {
      doc.mode = {
        type: 'autoEditorial',
        config: { ...doc.mode.config, style: validStyle },
      };
    }

    // Remove unlocked nodes by asset UUID or explicit node UUID
    const removeAssetSet = new Set(parseUUIDList(args.remove_asset_ids));
    const removeNodeSet = new Set(parseUUIDList(args.remove_node_ids));
    let removedCount = 0;
    const skippedLockedAssetIDs: string[] = [];
    const skippedLockedNodeIDs: string[] = [];

    if (removeAssetSet.size > 0 || removeNodeSet.size > 0) {
      const remaining: BoardNode[] = [];
      for (const node of doc.nodes) {
        const refAssetID = node.kind.type === 'assetRef' ? node.kind.assetID : null;
        const matchesAsset = refAssetID !== null && removeAssetSet.has(refAssetID);
        const matchesNode = removeNodeSet.has(node.id);
        if (matchesAsset || matchesNode) {
          if (node.isLocked) {
            if (matchesAsset && refAssetID) skippedLockedAssetIDs.push(refAssetID);
            if (matchesNode) skippedLockedNodeIDs.push(node.id);
            remaining.push(node);
          } else {
            removedCount++;
          }
        } else {
          remaining.push(node);
        }
      }
      doc.nodes = remaining;
      const survivingIDs = new Set(doc.nodes.map((n) => n.id));
      doc.connectors = doc.connectors.filter(
        (c) => survivingIDs.has(c.fromNodeID) && survivingIDs.has(c.toNodeID),
      );
    }

    // Non-overlapping placement below existing board content (maxY + 24)
    const now = new Date().toISOString();
    const maxY = doc.nodes.reduce((m, n) => Math.max(m, n.frame.y + n.frame.height), 16);
    let cursorY = maxY + 24;
    let nextZ = doc.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0) + 1;
    let nextOrder = doc.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), 0) + 1;
    const leftMargin = 32;
    const canvasWidth = 1108;

    // Optional section header
    const sectionTitle = asTrimmedString(args.add_section);
    if (sectionTitle) {
      const tintRaw = (asString(args.section_tint) ?? 'neutral').toLowerCase();
      const tint: GroupTint = (GROUP_TINTS as readonly string[]).includes(tintRaw)
        ? (tintRaw as GroupTint)
        : 'neutral';
      doc.nodes.push({
        id: toSwiftUUID(randomUUID()),
        kind: { type: 'groupFrame', title: sectionTitle.slice(0, 72), tint },
        frame: { x: leftMargin, y: cursorY, width: canvasWidth, height: 60 },
        zIndex: nextZ++,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: nextOrder++,
        updatedAt: now,
      });
      cursorY += 76;
    }

    // Append new asset cards in clean 4-column non-overlapping rows
    const addIDs = parseUUIDList(args.add_asset_ids);
    let addedCount = 0;
    const skippedMissingAssetIDs: string[] = [];
    if (addIDs.length > 0) {
      const existingRefs = new Set(getBoardReferencedAssetIDs(doc));
      const toAppend: AssetRecord[] = [];
      for (const aid of addIDs) {
        if (existingRefs.has(aid)) continue;
        const asset = this.deps.db.getAsset(aid);
        if (asset) {
          existingRefs.add(aid);
          toAppend.push(asset);
        } else {
          skippedMissingAssetIDs.push(aid);
        }
      }

      const gap = 18;
      const perRow = 4;
      const colWidth = (canvasWidth - gap * (perRow - 1)) / perRow;
      for (let rowStart = 0; rowStart < toAppend.length; rowStart += perRow) {
        const row = toAppend.slice(rowStart, rowStart + perRow);
        let rowMaxHeight = 160;
        for (let col = 0; col < row.length; col++) {
          const asset = row[col];
          const ratio = Math.max(0.6, Math.min(1.9, getAssetAspectRatio(asset)));
          const h = Math.min(360, Math.max(140, Math.round(colWidth / ratio)));
          rowMaxHeight = Math.max(rowMaxHeight, h);
          const x = leftMargin + col * (colWidth + gap);
          doc.nodes.push({
            id: toSwiftUUID(randomUUID()),
            kind: {
              type: 'assetRef',
              assetID: asset.id,
              crop: null,
              weight: 1,
              autoplayLoop: asset.mediaKind === 'animatedImage' || asset.mediaKind === 'video',
            },
            frame: { x, y: cursorY, width: colWidth, height: h },
            zIndex: nextZ++,
            rotationDegrees: 0,
            flipHorizontal: false,
            flipVertical: false,
            isLocked: false,
            editorialOrder: nextOrder++,
            updatedAt: now,
          });
          addedCount++;
        }
        cursorY += rowMaxHeight + gap;
      }
    }

    // Optional curator note placed cleanly below appended cards
    const noteText = asTrimmedString(args.add_note);
    if (noteText) {
      const noteTitle = asTrimmedString(args.note_title) ?? 'Agent 批注';
      const styleRawNote = (asString(args.note_style) ?? 'paper').toLowerCase();
      const noteStyle: NoteStyle = (NOTE_STYLES as readonly string[]).includes(styleRawNote)
        ? (styleRawNote as NoteStyle)
        : 'paper';
      doc.nodes.push({
        id: toSwiftUUID(randomUUID()),
        kind: { type: 'note', title: noteTitle, text: noteText, style: noteStyle, fontSize: 13.5 },
        frame: { x: leftMargin, y: cursorY, width: 360, height: 148 },
        zIndex: nextZ++,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: nextOrder++,
        updatedAt: now,
      });
    }

    const refIDs = getBoardReferencedAssetIDs(doc);
    const palette = this.curator.extractBoardPalette(refIDs, 6);
    if (palette.length > 0) {
      doc.extractedPalette = palette;
      doc.nodes = doc.nodes.map((node) => {
        if (node.kind.type === 'paletteStrip' && node.kind.autoSyncWithBoard) {
          return { ...node, kind: { ...node.kind, colors: palette } };
        }
        return node;
      });
    }
    doc.updatedAt = now;

    const saved = this.deps.db.saveBoardLocally(doc);
    this.deps.events.emitBoardUpdated(saved.id);

    const result: Record<string, unknown> = {
      boardID: saved.id,
      title: saved.title,
      mode: layoutModeLabel(saved.mode),
      itemCount: getBoardReferencedAssetIDs(saved).length,
      addedCount,
      removedCount,
      paletteHexes: saved.extractedPalette.map((c) => c.hex.toUpperCase()),
    };
    if (skippedLockedAssetIDs.length > 0) result.skippedLockedAssetIDs = skippedLockedAssetIDs;
    if (skippedLockedNodeIDs.length > 0) result.skippedLockedNodeIDs = skippedLockedNodeIDs;
    if (skippedMissingAssetIDs.length > 0) result.skippedMissingAssetIDs = skippedMissingAssetIDs;
    return jsonToolOutput(result);
  }

  private handleTrashAssets(args: Record<string, unknown>): MCPToolOutput {
    const ids = parseUUIDList(args.asset_ids);
    if (ids.length === 0) {
      return errorToolOutput('`asset_ids` must be a non-empty array of asset UUID strings.');
    }
    const trashed = asBool(args.trashed) ?? true;
    const updated = this.deps.db.applyBatchPatch(
      createDefaultAssetBatchPatch(ids, { isTrashed: trashed }),
    );
    const updatedSet = new Set(updated.map((a) => a.id));
    const skippedIDs = ids.filter((id) => !updatedSet.has(id));

    if (updated.length > 0) {
      this.deps.events.emitLibraryChanged(
        trashed ? 'mcp.trash_assets' : 'mcp.restore_assets',
        updated.map((a) => a.id),
      );
    }

    const result: Record<string, unknown> = {
      updatedCount: updated.length,
      trashed,
      assetIDs: updated.map((a) => a.id),
      note: 'Soft Trash only; external agents can never permanently delete assets.',
    };
    if (skippedIDs.length > 0) result.skippedIDs = skippedIDs;
    return jsonToolOutput(result);
  }

  private async handleAnalyzeAssets(args: Record<string, unknown>): Promise<MCPToolOutput> {
    const ids = parseUUIDList(args.asset_ids).slice(0, 20);
    if (ids.length === 0) {
      return errorToolOutput('`asset_ids` must be a non-empty array of asset UUID strings (max 20).');
    }
    const refreshRich = asBool(args.refresh_rich_metadata) ?? false;
    const syncCfg = this.deps.configStore.getSyncConfig();
    const seen = new Set<UUID>();
    const analyzed: AssetRecord[] = [];

    for (const id of ids) {
      if (seen.has(id)) continue;
      seen.add(id);
      const before = this.deps.db.getAsset(id);
      if (!before) continue;

      let current = before;
      // 1. Hydrate EXIF / AI generation metadata for image/animatedImage/designFile
      const hydrated = await this.deps.media.hydrateImageMetadata(current).catch(() => null);
      if (hydrated) {
        current = hydrated;
      }

      // 2. Refresh dominant colors & visual feature print from thumbnail
      const thumbBuf = await this.deps.media.readThumbnailBuffer(id, 'grid520');
      let colors = current.dominantColors;
      let fp: number[] = [];
      if (thumbBuf && thumbBuf.byteLength > 0) {
        const [extractedColors, extractedFp] = await Promise.all([
          current.mediaKind === 'audio'
            ? Promise.resolve(current.dominantColors)
            : this.deps.media.extractDominantColors(thumbBuf, 6).catch(() => current.dominantColors),
          this.deps.media.computeVisualFingerprint(thumbBuf).catch(() => []),
        ]);
        if (extractedColors.length > 0 && current.mediaKind !== 'audio') {
          colors = extractedColors;
        }
        fp = extractedFp;
      }

      let saved = this.deps.db.transaction(() => {
        const latest = this.deps.db.getAsset(id);
        if (!latest || latest.contentHash !== before.contentHash) return null;
        const next: AssetRecord = {
          ...latest,
          dominantColors: colors,
          richMetadata: current.richMetadata ?? latest.richMetadata ?? null,
        };
        if (fp.length > 0) {
          const vec = {
            featurePrint: encodeFeaturePrintFloat32(fp),
            embedding: null,
            embeddingModel: null,
            precision: 16 as const,
          };
          if (syncCfg.syncEmbeddings) this.deps.db.recordSyncChange({ type: 'vector', id, vector: vec });
          else this.deps.db.saveVector(id, vec);
        }
        return this.deps.db.saveAssetLocally(next);
      });

      // 3. Optionally refresh live GitHub / Social rich metadata for web bookmarks
      if (saved && refreshRich && saved.mediaKind === 'webBookmark' && saved.sourceURL) {
        try {
          const refreshed = await this.deps.media.refreshRichAsset(saved);
          saved = this.deps.db.saveAssetLocally(refreshed.asset);
          if (refreshed.vector) {
            this.deps.db.saveVector(saved.id, refreshed.vector);
          }
          this.deps.db.markProjection('thumbnails', saved.id);
        } catch {
          // keep locally analyzed record if remote fetch fails
        }
      }

      if (saved) analyzed.push(saved);
    }

    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    if (analyzed.length > 0) {
      this.deps.events.emitLibraryEnriched(analyzed.map((a) => a.id));
    }

    return jsonToolOutput({
      analyzedCount: analyzed.length,
      refreshedRichMetadata: refreshRich,
      assets: analyzed.map((a) => this.serializeAssetSummary(a, folderPathByID)),
    });
  }

  // MARK: - Helpers

  private appendAssetsToBoard(boardID: UUID, assets: readonly AssetRecord[]): void {
    const board = this.deps.db.getBoard(boardID);
    if (!board || assets.length === 0) return;

    const existingRefs = new Set(getBoardReferencedAssetIDs(board));
    const now = new Date().toISOString();
    const maxY = board.nodes.reduce((m, n) => Math.max(m, n.frame.y + n.frame.height), 16);
    let cursorY = maxY + 24;
    let rowMaxH = 0;
    let maxZ = board.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
    let maxOrder = board.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
    const newNodes: BoardNode[] = [...board.nodes];
    let added = 0;

    for (let idx = 0; idx < assets.length; idx++) {
      const asset = assets[idx];
      if (existingRefs.has(asset.id)) continue;
      existingRefs.add(asset.id);
      const ratio = Math.max(0.6, Math.min(1.9, getAssetAspectRatio(asset)));
      const w = 264;
      const h = Math.min(360, Math.max(140, Math.round(w / ratio)));
      const col = added % 4;
      if (added > 0 && col === 0) {
        cursorY += Math.max(rowMaxH, 240) + 24;
        rowMaxH = 0;
      }
      rowMaxH = Math.max(rowMaxH, h);
      newNodes.push({
        id: toSwiftUUID(randomUUID()),
        kind: {
          type: 'assetRef',
          assetID: asset.id,
          crop: null,
          weight: 1,
          autoplayLoop: asset.mediaKind === 'animatedImage' || asset.mediaKind === 'video',
        },
        frame: { x: 32 + col * 282, y: cursorY, width: w, height: h },
        zIndex: ++maxZ,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: ++maxOrder,
        updatedAt: now,
      });
      added++;
    }

    if (added > 0) {
      const refAssets: AssetRecord[] = [];
      for (const n of newNodes) {
        if (n.kind.type === 'assetRef') {
          const a = this.deps.db.getAsset(n.kind.assetID);
          if (a) refAssets.push(a);
        }
      }
      const extractedPalette =
        refAssets.length > 0
          ? MoodboardCurator.harmonizePalette(
              refAssets.flatMap((a) => a.dominantColors),
              6,
            )
          : board.extractedPalette;
      this.deps.db.saveBoardLocally({ ...board, nodes: newNodes, extractedPalette, updatedAt: now });
      this.deps.events.emitBoardUpdated(board.id);
    }
  }

  private resolveBoard(args: Record<string, unknown>): MoodboardDocument | null {
    const boardID = parseUUID(args.board_id ?? args.id);
    if (boardID) return this.deps.db.getBoard(boardID);
    const title = asTrimmedString(args.title);
    if (title) return this.deps.db.findBoardByTitle(title);
    return null;
  }

  private resolveOptionalSmartFolder(args: Record<string, unknown>): SmartFolderRecord | null {
    const rawID = asTrimmedString(args.smart_folder_id);
    const rawName = asTrimmedString(args.smart_folder_name);
    if (!rawID && !rawName) return null;

    const all = this.deps.db.fetchSmartFolders();
    if (rawID) {
      const uuid = parseUUID(rawID);
      if (!uuid) throw new Error(`Invalid smart_folder_id UUID: ${rawID}`);
      const found = all.find((s) => s.id === uuid);
      if (!found) throw new Error(`Smart folder not found: ${rawID}`);
      return found;
    }
    const lower = rawName!.toLowerCase();
    const exact = all.find((s) => s.name.toLowerCase() === lower);
    if (exact) return exact;
    const partial = all.find((s) => s.name.toLowerCase().includes(lower));
    if (partial) return partial;
    throw new Error(`Smart folder not found: ${rawName}`);
  }

  private buildFilterCriteria(
    args: Record<string, unknown>,
    folders: FolderRecord[],
    folderPathByID: Map<UUID, string>,
  ): FilterCriteria {
    const query = asTrimmedString(args.query) ?? '';
    const tags = asStringArray(args.tags) ?? [];
    const colorHex = asTrimmedString(args.color_hex);
    const colorTolerance = asNumber(args.color_tolerance) ?? 28.0;
    const minRating = asInt(args.min_rating) ?? 0;
    const onlyInbox = asBool(args.only_inbox) ?? false;
    const onlyUntagged = asBool(args.only_untagged) ?? false;
    const includeSubfolders = asBool(args.include_subfolders) ?? false;
    const recentRaw = asInt(args.only_recent_days);
    const onlyRecentDays = recentRaw !== null ? Math.max(1, recentRaw) : null;
    const onlyPinnedOffline = asBool(args.only_pinned_offline) ?? false;
    const onlyTrashed = asBool(args.only_trashed) ?? false;
    const includeTrashed = (asBool(args.include_trashed) ?? false) || onlyTrashed;
    const folderID = this.resolveOptionalFolderID(args, folders, folderPathByID);
    const kinds = parseMediaKinds(args.media_kinds);
    const shapeRaw = asTrimmedString(args.aspect_shape);
    const shape: AspectShape | null =
      shapeRaw && (ASPECT_SHAPES as readonly string[]).includes(shapeRaw)
        ? (shapeRaw as AspectShape)
        : null;
    const defaultSort: SortOrder = query ? 'relevance' : 'newest';
    const sortBy = parseSortOrder(args.sort_by, defaultSort);

    return createDefaultFilterCriteria({
      searchQuery: query,
      kinds,
      selectedColorHex: colorHex,
      colorTolerance,
      shape,
      minRating,
      tags,
      folderID: onlyInbox ? null : folderID,
      includeSubfolders,
      onlyInbox,
      onlyUntagged,
      onlyRecentDays,
      onlyPinnedOffline,
      includeTrashed,
      onlyTrashed,
      sortBy,
    });
  }

  private resolveOptionalFolderID(
    args: Record<string, unknown>,
    folders: FolderRecord[],
    folderPathByID: Map<UUID, string>,
  ): UUID | null {
    const rawID = asTrimmedString(args.folder_id);
    if (rawID) {
      const id = parseUUID(rawID);
      if (!id) throw new Error(`Invalid folder_id UUID: ${rawID}`);
      return id;
    }
    const folderPath = asTrimmedString(args.folder_path);
    if (folderPath) {
      const lower = folderPath.toLowerCase();
      for (const [id, p] of folderPathByID.entries()) {
        if (p.toLowerCase() === lower) return id;
      }
      const byName = folders.find((f) => f.name.toLowerCase() === lower);
      if (byName) return byName.id;
      throw new Error(`Folder not found: ${folderPath}`);
    }
    return null;
  }

  private serializeAssetSummary(
    asset: AssetRecord,
    folderPathByID: Map<UUID, string>,
  ): Record<string, unknown> {
    return {
      id: asset.id,
      title: asset.title,
      fileName: asset.fileName,
      mediaKind: asset.mediaKind,
      folderID: asset.folderID ?? '',
      folderPath: (asset.folderID && folderPathByID.get(asset.folderID)) || 'Inbox',
      tags: asset.tags,
      rating: asset.rating,
      aspectRatio: Math.round(getAssetAspectRatio(asset) * 100) / 100,
      dominantColors: asset.dominantColors.slice(0, 5).map((c) => c.hex.toUpperCase()),
      aiDescription: asset.aiDescription ?? '',
      notes: asset.notes,
      sourceURL: asset.sourceURL ?? '',
    };
  }

  private serializeRichMetadata(rich?: AssetRichMetadata | null): Record<string, unknown> | null {
    if (!rich) return null;
    const out: Record<string, unknown> = {};

    if (rich.photoExif && !isPhotoExifEmpty(rich.photoExif)) {
      const exif = rich.photoExif;
      const e: Record<string, unknown> = {
        hasMeaningfulCameraExif: hasMeaningfulCameraExif(exif),
      };
      const displayName = getPhotoExifCameraDisplayName(exif);
      const aperture = formatPhotoExifAperture(exif);
      const summary = getPhotoExifExposureSummary(exif);
      if (exif.cameraMake) e.cameraMake = exif.cameraMake;
      if (exif.cameraModel) e.cameraModel = exif.cameraModel;
      if (displayName) e.cameraDisplayName = displayName;
      if (exif.lensModel) e.lensModel = exif.lensModel;
      if (exif.capturedAt) e.capturedAt = exif.capturedAt;
      if (exif.exposureTime) e.exposureTime = exif.exposureTime;
      if (exif.fNumber != null) e.fNumber = exif.fNumber;
      if (aperture) e.aperture = aperture;
      if (exif.iso != null) e.iso = exif.iso;
      if (exif.focalLengthMM != null) e.focalLengthMM = exif.focalLengthMM;
      if (exif.focalLength35mm != null) e.focalLength35mm = exif.focalLength35mm;
      if (summary) e.exposureSummary = summary;
      if (exif.exposureBiasEV != null) e.exposureBiasEV = exif.exposureBiasEV;
      if (exif.meteringMode) e.meteringMode = exif.meteringMode;
      if (exif.flashFired != null) e.flashFired = exif.flashFired;
      if (exif.whiteBalance) e.whiteBalance = exif.whiteBalance;
      if (exif.colorProfile) e.colorProfile = exif.colorProfile;
      if (exif.bitDepth != null) e.bitDepth = exif.bitDepth;
      if (exif.dpiWidth != null) e.dpiWidth = exif.dpiWidth;
      if (exif.software) e.software = exif.software;
      if (exif.artist) e.artist = exif.artist;
      if (exif.copyright) e.copyright = exif.copyright;
      if (exif.latitude != null && exif.longitude != null) {
        const gps: Record<string, number> = {
          latitude: exif.latitude,
          longitude: exif.longitude,
        };
        if (exif.altitudeMeters != null) gps.altitudeMeters = exif.altitudeMeters;
        e.gps = gps;
      }
      out.photoExif = e;
    }

    if (rich.aiGeneration && !isAIGenerationEmpty(rich.aiGeneration)) {
      const ai = rich.aiGeneration;
      const g: Record<string, unknown> = {};
      if (ai.generator) g.generator = ai.generator;
      if (ai.prompt) g.prompt = ai.prompt;
      if (ai.negativePrompt) g.negativePrompt = ai.negativePrompt;
      if (ai.modelName) g.modelName = ai.modelName;
      if (ai.modelHash) g.modelHash = ai.modelHash;
      if (ai.sampler) g.sampler = ai.sampler;
      if (ai.scheduler) g.scheduler = ai.scheduler;
      if (ai.steps != null) g.steps = ai.steps;
      if (ai.cfgScale != null) g.cfgScale = ai.cfgScale;
      if (ai.seed) g.seed = ai.seed;
      if (ai.sizeText) g.sizeText = ai.sizeText;
      if (ai.clipSkip != null) g.clipSkip = ai.clipSkip;
      if (ai.loras.length > 0) g.loras = ai.loras;
      if (Object.keys(ai.extraParameters).length > 0) g.extraParameters = ai.extraParameters;
      out.aiGeneration = g;
    }

    if (rich.socialPost) {
      const post = rich.socialPost;
      const s: Record<string, unknown> = {
        platform: post.platform,
        authorName: post.authorName,
        authorHandle: post.authorHandle,
        bodyText: post.bodyText,
        originalURL: post.originalURL,
        hasVideo: post.hasVideo,
        attachments: getEffectiveSocialAttachments(post).map((att) => ({
          kind: att.kind,
          url: att.url,
          thumbnailURL: att.thumbnailURL ?? '',
        })),
      };
      if (post.publishedAtText) s.publishedAtText = post.publishedAtText;
      if (post.quotedAuthor) s.quotedAuthor = post.quotedAuthor;
      if (post.quotedText) s.quotedText = post.quotedText;
      if (post.articleTitle) s.articleTitle = post.articleTitle;
      if (post.likeCount != null) s.likeCount = post.likeCount;
      if (post.repostCount != null) s.repostCount = post.repostCount;
      if (post.replyCount != null) s.replyCount = post.replyCount;
      if (post.viewCount != null) s.viewCount = post.viewCount;
      out.socialPost = s;
    }

    if (rich.githubRepo) {
      const repo = rich.githubRepo;
      const r: Record<string, unknown> = {
        owner: repo.owner,
        repo: repo.repo,
        fullName: repo.fullName,
        stars: repo.stars,
        forks: repo.forks,
        topics: repo.topics,
        defaultBranch: repo.defaultBranch,
      };
      if (repo.description) r.description = repo.description;
      if (repo.watchers != null) r.watchers = repo.watchers;
      if (repo.language) r.language = repo.language;
      if (repo.licenseName) r.licenseName = repo.licenseName;
      if (repo.homepageURL) r.homepageURL = repo.homepageURL;
      if (repo.readmeMarkdown) r.readmeExcerpt = repo.readmeMarkdown.slice(0, 2000);
      out.githubRepo = r;
    }

    if (rich.textExcerpt) out.textExcerpt = rich.textExcerpt;
    if (rich.isMarkdown) out.isMarkdown = true;
    if (rich.model3DFormat) out.model3DFormat = rich.model3DFormat;

    return Object.keys(out).length > 0 ? out : null;
  }

  private makeResultResponse(id: unknown, result: unknown): Record<string, unknown> {
    return {
      jsonrpc: '2.0',
      id: id ?? null,
      result,
    };
  }

  private makeErrorResponse(id: unknown, code: number, message: string): Record<string, unknown> {
    return {
      jsonrpc: '2.0',
      id: id ?? null,
      error: { code, message },
    };
  }
}
