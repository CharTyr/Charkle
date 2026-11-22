import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  createDefaultAssetBatchPatch,
  createDefaultFilterCriteria,
  createDefaultMoodboardCurationRequest,
  EDITORIAL_STYLES,
  externalAgentAllowsRead,
  externalAgentAllowsWrite,
  getAssetAspectRatio,
  getBoardReferencedAssetIDs,
  GROUP_TINTS,
  MEDIA_KINDS,
  toSwiftUUID,
  type AssetRecord,
  type BoardLayoutMode,
  type CaptureInput,
  type EditorialStyle,
  type ExternalAgentConfig,
  type FilterCriteria,
  type FolderAssignment,
  type FolderRecord,
  type GroupTint,
  type MediaKind,
  type MoodboardDocument,
  type UUID,
} from '@charkle/shared';
import type { EventBus } from '../api/events.js';
import type { IMediaPipeline } from '../context.js';
import type { LibraryDatabase } from '../db/library-database.js';
import type { ConfigStore } from '../storage/config-store.js';
import { MoodboardExporter } from '../export/moodboard-exporter.js';
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
import type { VisualGroundingEngine } from '../intelligence/visual-grounding-engine.js';

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
  getCloudAIProvider?: () => CloudAIProvider | null;
  getTypeSafeAPIKey?: () => string | null;
  grounding?: VisualGroundingEngine | null;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const WRITE_TOOL_NAMES = new Set([
  'organize_assets',
  'create_folder',
  'ingest_asset',
  'compose_moodboard',
  'patch_moodboard',
  'trash_assets',
]);

function expandTilde(filePath: string): string {
  if (filePath.startsWith('~/')) {
    return path.join(os.homedir(), filePath.slice(2));
  }
  return filePath;
}

function asString(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

function asTrimmedString(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return t.length > 0 ? t : null;
}

function asBool(v: unknown): boolean | null {
  return typeof v === 'boolean' ? v : null;
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

function layoutModeLabel(mode: BoardLayoutMode): string {
  return mode.type === 'autoEditorial' ? `autoEditorial(${mode.config.style})` : 'freeform';
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

/**
 * Grounded External Agent Service & 14-Tool JSON-RPC 2.0 MCP Server.
 * Powers BOTH HTTP `POST /api/v1/mcp` and stdio `packages/server/src/mcp-stdio.ts`.
 */
export class ExternalAgentService {
  private readonly deps: ExternalAgentServiceDeps;
  private readonly tools: CharkleAgentTools;
  private readonly curator: MoodboardCurator;
  private readonly harness: MoodboardAgentHarness;

  constructor(deps: ExternalAgentServiceDeps) {
    this.deps = deps;
    this.tools = new CharkleAgentTools(deps.db, deps.media);
    this.curator = new MoodboardCurator(deps.db);
    this.harness = new MoodboardAgentHarness(deps.db, deps.media);
  }

  currentPolicy(): ExternalAgentConfig {
    return this.deps.configStore.getExternalAgentConfig();
  }

  // MARK: - JSON-RPC 2.0 Dispatcher

  /**
   * Handles a single JSON-RPC 2.0 message (object or raw JSON string) and returns the response object,
   * or `null` for JSON-RPC notifications that expect no reply.
   */
  async handleJSONRPC(payload: string | Record<string, unknown>): Promise<Record<string, unknown> | null> {
    let obj: Record<string, unknown>;
    if (typeof payload === 'string') {
      try {
        const parsed = JSON.parse(payload) as unknown;
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
          return this.makeErrorResponse(null, -32700, 'Parse error: invalid JSON');
        }
        obj = parsed as Record<string, unknown>;
      } catch {
        return this.makeErrorResponse(null, -32700, 'Parse error: invalid JSON');
      }
    } else {
      obj = payload;
    }

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

    switch (method) {
      case 'initialize': {
        const requestedVersion = asString(params.protocolVersion) ?? '2025-03-26';
        return this.makeResultResponse(id, {
          protocolVersion: requestedVersion,
          capabilities: {
            tools: { listChanged: false },
            resources: { subscribe: false, listChanged: false },
          },
          serverInfo: {
            name: 'charkle',
            version: '1.0.0',
          },
          instructions:
            'Charkle is a visual reference library and moodboard studio. Use `library_overview` to inspect folders and tags, `search_assets` / `list_inbox` to find candidates, `render_contact_sheet` to visually inspect up to 16 numbered thumbnails in one image, `get_board_context` / `export_board_image` to inspect moodboards, and write tools (`organize_assets`, `compose_moodboard`, `patch_moodboard`, `ingest_asset`, `trash_assets`) when write access is enabled in Charkle Settings.',
        });
      }

      case 'notifications/initialized':
      case 'notifications/cancelled':
      case 'initialized':
        return null;

      case 'ping':
        return this.makeResultResponse(id, {});

      case 'tools/list':
        return this.makeResultResponse(id, { tools: ExternalAgentService.mcpToolDefinitions() });

      case 'tools/call': {
        const name = asString(params.name);
        if (!name) {
          return this.makeErrorResponse(id, -32602, 'Invalid params: missing tool name');
        }
        const args =
          params.arguments && typeof params.arguments === 'object' && !Array.isArray(params.arguments)
            ? (params.arguments as Record<string, unknown>)
            : {};
        const output = await this.callTool(name, args);
        return this.makeResultResponse(id, {
          content: output.content,
          isError: output.isError,
        });
      }

      case 'resources/list':
        return this.makeResultResponse(id, {
          resources: [
            {
              uri: 'charkle://library/overview',
              name: 'Charkle Library Overview',
              description:
                'Folders, top tags, media distribution, and counts for the Charkle library.',
              mimeType: 'application/json',
            },
            {
              uri: 'charkle://boards',
              name: 'Charkle Moodboards',
              description: 'Summary list of all moodboards in Charkle.',
              mimeType: 'application/json',
            },
          ],
        });

      case 'resources/read': {
        const uri = asString(params.uri);
        if (!uri) {
          return this.makeErrorResponse(id, -32602, 'Missing resource uri');
        }
        const policy = this.currentPolicy();
        if (!externalAgentAllowsRead(policy)) {
          return this.makeErrorResponse(
            id,
            -32001,
            'Charkle external agent access is disabled in Settings.',
          );
        }
        if (uri === 'charkle://library/overview') {
          const out = await this.callTool('library_overview', {});
          const text = out.content
            .filter((c): c is { type: 'text'; text: string } => c.type === 'text')
            .map((c) => c.text)
            .join('\n');
          return this.makeResultResponse(id, {
            contents: [{ uri, mimeType: 'application/json', text }],
          });
        }
        if (uri === 'charkle://boards') {
          const out = await this.callTool('list_boards', {});
          const text = out.content
            .filter((c): c is { type: 'text'; text: string } => c.type === 'text')
            .map((c) => c.text)
            .join('\n');
          return this.makeResultResponse(id, {
            contents: [{ uri, mimeType: 'application/json', text }],
          });
        }
        return this.makeErrorResponse(id, -32002, `Unknown resource URI: ${uri}`);
      }

      default:
        if (isNotification) return null;
        return this.makeErrorResponse(id, -32601, `Method not found: ${method}`);
    }
  }

  // MARK: - Tool Dispatcher & Policy Enforcement

  async callTool(name: string, args: Record<string, unknown> = {}): Promise<MCPToolOutput> {
    const policy = this.currentPolicy();
    if (!externalAgentAllowsRead(policy)) {
      return errorToolOutput(
        '外部 Agent 接入已在 Charkle「设置 → 外部 Agent 与 MCP」中关闭，请先开启后再试。',
      );
    }
    if (WRITE_TOOL_NAMES.has(name) && !externalAgentAllowsWrite(policy)) {
      return errorToolOutput(
        `当前 Charkle 外部 Agent 权限为「仅只读检索与导出」，无法执行写入操作「${name}」。请在 Charkle「设置 → 外部 Agent 与 MCP」中切换为「允许整理与生成情绪板」。`,
      );
    }

    try {
      switch (name) {
        case 'library_overview':
          return this.handleLibraryOverview(policy);
        case 'search_assets':
          return this.handleSearchAssets(args);
        case 'list_inbox':
          return this.handleListInbox(args);
        case 'get_asset':
          return this.handleGetAsset(args);
        case 'render_contact_sheet':
          return await this.handleRenderContactSheet(args);
        case 'list_boards':
          return this.handleListBoards();
        case 'get_board_context':
          return this.handleGetBoardContext(args);
        case 'export_board_image':
          return await this.handleExportBoardImage(args);
        case 'organize_assets':
          return this.handleOrganizeAssets(args);
        case 'create_folder':
          return this.handleCreateFolder(args);
        case 'ingest_asset':
          return await this.handleIngestAsset(args);
        case 'compose_moodboard':
          return await this.handleComposeMoodboard(args);
        case 'patch_moodboard':
          return this.handlePatchMoodboard(args);
        case 'trash_assets':
          return this.handleTrashAssets(args);
        default:
          return errorToolOutput(`Unknown Charkle tool: ${name}`);
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return errorToolOutput(`Tool ${name} failed: ${msg}`);
    }
  }

  // MARK: - 8 Read Tool Handlers

  private handleLibraryOverview(policy: ExternalAgentConfig): MCPToolOutput {
    const overview = this.tools.libraryOverview();
    return jsonToolOutput({
      totalAssets: overview.totalAssets,
      inboxCount: overview.inboxCount,
      boardCount: overview.boardCount,
      accessLevel: policy.accessLevel,
      canWrite: externalAgentAllowsWrite(policy),
      mediaKindCounts: overview.mediaKindCounts,
      folders: overview.folders,
      topTags: overview.topTags.slice(0, 40),
    });
  }

  private handleSearchAssets(args: Record<string, unknown>): MCPToolOutput {
    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const criteria = this.buildFilterCriteria(args, folders, folderPathByID);
    const limit = Math.max(1, Math.min(100, asInt(args.limit) ?? 30));

    const matches = this.deps.db.fetchAssets(criteria);
    const sliced = matches.slice(0, limit);
    return jsonToolOutput({
      totalMatched: matches.length,
      returned: sliced.length,
      assets: sliced.map((a) => this.serializeAssetSummary(a, folderPathByID)),
    });
  }

  private handleListInbox(args: Record<string, unknown>): MCPToolOutput {
    const limit = Math.max(1, Math.min(100, asInt(args.limit) ?? 40));
    const matches = this.deps.db.fetchAssets({ onlyInbox: true, sortBy: 'newest' });
    const sliced = matches.slice(0, limit);
    return jsonToolOutput({
      inboxTotal: matches.length,
      returned: sliced.length,
      assets: sliced.map((a) => this.serializeAssetSummary(a, new Map())),
    });
  }

  private handleGetAsset(args: Record<string, unknown>): MCPToolOutput {
    const assetID = parseUUID(args.asset_id ?? args.id);
    if (!assetID) {
      return errorToolOutput('Missing or invalid UUID for `asset_id`.');
    }
    const asset = this.deps.db.getAsset(assetID);
    if (!asset) {
      return errorToolOutput(`Asset not found: ${assetID}`);
    }
    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const thumbPath = this.deps.media.getThumbnailPath(assetID, 'grid520') ?? '';
    const origPath = this.deps.media.getOriginalPath(asset) ?? '';

    return jsonToolOutput({
      ...this.serializeAssetSummary(asset, folderPathByID),
      ocrText: asset.ocrText ?? '',
      suggestedTags: asset.suggestedTags,
      sourceDomain: asset.sourceDomain ?? '',
      fileSizeBytes: asset.fileSizeBytes,
      pixelWidth: asset.pixelWidth,
      pixelHeight: asset.pixelHeight,
      thumbnailPath: thumbPath,
      localOriginalPath: origPath,
      isTrashed: asset.isTrashed,
    });
  }

  private async handleRenderContactSheet(args: Record<string, unknown>): Promise<MCPToolOutput> {
    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);

    let selectedAssets: AssetRecord[] = [];
    const rawIDs = parseUUIDList(args.asset_ids);
    if (rawIDs.length > 0) {
      for (const id of rawIDs.slice(0, 16)) {
        const asset = this.deps.db.getAsset(id);
        if (asset) selectedAssets.push(asset);
      }
    } else {
      const criteria = this.buildFilterCriteria(args, folders, folderPathByID);
      const limit = Math.max(1, Math.min(16, asInt(args.limit) ?? 16));
      selectedAssets = this.deps.db.fetchAssets(criteria, limit);
    }

    if (selectedAssets.length === 0) {
      return jsonToolOutput({
        slots: [],
        message: 'No assets matched the requested filter or asset_ids.',
      });
    }

    const pkg = await this.tools.buildContactSheets({
      candidates: selectedAssets,
      folderPathByID,
      sheetCapacity: 16,
      format: 'jpeg',
    });
    const sheet = pkg.sheets[0];
    if (!sheet) {
      return errorToolOutput('Failed to render Contact Sheet image.');
    }

    let savedPath: string | undefined;
    const outPath = asTrimmedString(args.output_path);
    if (outPath) {
      const resolved = path.resolve(expandTilde(outPath));
      fs.mkdirSync(path.dirname(resolved), { recursive: true });
      fs.writeFileSync(resolved, sheet.jpegData);
      savedPath = resolved;
    }

    const slots = sheet.orderedSlots
      .map((pair) => {
        const asset = pkg.slotToAsset.get(pair.slot);
        if (!asset) return null;
        return {
          slot: pair.slot,
          badge: `#${String(pair.slot).padStart(2, '0')}`,
          assetID: asset.id,
          title: asset.title,
          folderPath: (asset.folderID && folderPathByID.get(asset.folderID)) || 'Inbox',
          tags: asset.tags,
          dominantColors: asset.dominantColors.slice(0, 4).map((c) => c.hex.toUpperCase()),
          aiDescription: asset.aiDescription ?? '',
        };
      })
      .filter(Boolean);

    const metadata: Record<string, unknown> = {
      sheetWidth: sheet.width,
      sheetHeight: sheet.height,
      slotCount: slots.length,
      slots,
    };
    if (savedPath) metadata.savedPath = savedPath;

    return {
      content: [
        { type: 'image', mimeType: 'image/jpeg', data: sheet.jpegData.toString('base64') },
        { type: 'text', text: JSON.stringify(metadata, null, 2) },
      ],
      isError: false,
    };
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
        paletteHexes: b.paletteHexes,
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
    const assetsByID = new Map<UUID, AssetRecord>();
    for (const id of refIDs) {
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
        });
      } else if (node.kind.type === 'groupFrame') {
        sections.push({
          nodeID: node.id,
          title: node.kind.title,
          tint: node.kind.tint,
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
        };
        const origPath = this.deps.media.getOriginalPath(asset);
        if (origPath) summary.localOriginalPath = origPath;
        cardRefs.push(summary);
      }
    }

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
      itemCount: cardRefs.length,
      palette,
      notes,
      sections,
      assets: cardRefs,
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
    const rendered = await MoodboardExporter.exportImage({
      document: doc,
      assetsByID,
      loadAssetBuffer: async (assetID, tier) =>
        (await this.deps.media.readThumbnailBuffer(assetID, tier)) ??
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
      bytes: rendered.buffer.length,
      mimeType: 'image/png',
    };

    const outPath = asTrimmedString(args.output_path);
    if (outPath) {
      const resolved = path.resolve(expandTilde(outPath));
      fs.mkdirSync(path.dirname(resolved), { recursive: true });
      fs.writeFileSync(resolved, rendered.buffer);
      metadata.savedPath = resolved;
    }

    return {
      content: [
        { type: 'image', mimeType: 'image/png', data: rendered.buffer.toString('base64') },
        { type: 'text', text: JSON.stringify(metadata, null, 2) },
      ],
      isError: false,
    };
  }

  // MARK: - 6 Write Tool Handlers (Never Permanent Delete)

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
      folderAssignment,
    });

    const updated = this.deps.db.applyBatchPatch(patch);

    const aiDesc = asTrimmedString(args.ai_description);
    if (aiDesc) {
      this.tools.persistVisualInsights(
        ids.map((assetID) => ({ assetID, description: aiDesc, tags: [] })),
      );
    }

    this.deps.events.emitLibraryChanged(
      'mcp.organize_assets',
      updated.map((a) => a.id),
    );

    return jsonToolOutput({
      updatedCount: updated.length,
      assetIDs: updated.map((a) => a.id),
    });
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
    const created = this.deps.db.createFolder(name, parentID);
    this.deps.events.emitLibraryChanged('mcp.create_folder', undefined, [created.id]);

    return jsonToolOutput({
      id: created.id,
      name: created.name,
      parentID: created.parentID ?? '',
    });
  }

  private async handleIngestAsset(args: Record<string, unknown>): Promise<MCPToolOutput> {
    const folders = this.deps.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const targetFolderID = this.resolveOptionalFolderID(args, folders, folderPathByID);

    let input: CaptureInput;
    const filePath = asTrimmedString(args.file_path);
    const webURL = asTrimmedString(args.web_url);
    const text = asTrimmedString(args.text);
    const title = asTrimmedString(args.title);

    if (filePath) {
      const resolved = path.resolve(expandTilde(filePath));
      if (!fs.existsSync(resolved)) {
        return errorToolOutput(`File not found at path: ${resolved}`);
      }
      input = { type: 'fileURL', url: resolved };
    } else if (webURL) {
      try {
        const parsed = new URL(webURL);
        if (!parsed.protocol) throw new Error('Invalid URL');
      } catch {
        return errorToolOutput(`Invalid web_url: ${webURL}`);
      }
      input = { type: 'webURL', url: webURL, title, notes: null };
    } else if (text) {
      input = { type: 'textSnippet', title: title ?? 'Agent 笔记', text, sourceURL: null };
    } else {
      return errorToolOutput('Provide one of `file_path`, `web_url`, or `text`.');
    }

    const ingested = await this.deps.media.ingest(input, targetFolderID);
    let saved = this.deps.db.transaction(() => {
      const persisted = this.deps.db.saveAssetLocally(ingested.asset);
      this.deps.db.touchOriginal(persisted.id);
      if (ingested.vector) {
        this.deps.db.saveVector(persisted.id, ingested.vector);
      }
      return persisted;
    });

    const tags = asStringArray(args.tags);
    if (tags && tags.length > 0) {
      const patched = this.deps.db.applyBatchPatch(
        createDefaultAssetBatchPatch([saved.id], { addTags: tags }),
      );
      if (patched[0]) saved = patched[0];
    }

    this.deps.events.emitLibraryChanged('mcp.ingest_asset', [saved.id]);

    return jsonToolOutput({
      importedCount: 1,
      assets: [this.serializeAssetSummary(saved, folderPathByID)],
    });
  }

  private async handleComposeMoodboard(args: Record<string, unknown>): Promise<MCPToolOutput> {
    const title = asTrimmedString(args.title) ?? '';
    const subtitle = asTrimmedString(args.subtitle) ?? '';
    const layoutRaw = (asString(args.layout_style) ?? 'magazine').toLowerCase();
    const layoutStyle: EditorialStyle = (EDITORIAL_STYLES as readonly string[]).includes(layoutRaw)
      ? (layoutRaw as EditorialStyle)
      : 'magazine';
    const useFreeform = asBool(args.use_freeform) ?? false;

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
        itemCount: getBoardReferencedAssetIDs(saved).length,
        paletteHexes: saved.extractedPalette.map((c) => c.hex.toUpperCase()),
      });
    }

    // Mode B: Prompt-driven automatic curation via MoodboardAgentHarness
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

    const req = createDefaultMoodboardCurationRequest({
      prompt,
      scopeFolderIDs: scopeID ? [scopeID] : [],
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
    };

    const newTitle = asTrimmedString(args.new_title);
    if (newTitle) doc.title = newTitle;
    if (typeof args.subtitle === 'string') doc.subtitle = args.subtitle.trim();

    const removeSet = new Set(parseUUIDList(args.remove_asset_ids));
    if (removeSet.size > 0) {
      doc.nodes = doc.nodes.filter((node) => {
        if (node.kind.type !== 'assetRef') return true;
        return !(removeSet.has(node.kind.assetID) && !node.isLocked);
      });
    }

    const addIDs = parseUUIDList(args.add_asset_ids);
    const now = new Date().toISOString();
    if (addIDs.length > 0) {
      const existingRefs = new Set(getBoardReferencedAssetIDs(doc));
      let nextZ = doc.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0) + 1;
      let nextOrder = doc.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), 0) + 1;
      for (const aid of addIDs) {
        if (existingRefs.has(aid)) continue;
        const asset = this.deps.db.getAsset(aid);
        if (!asset) continue;
        existingRefs.add(aid);
        const ratio = Math.max(0.6, Math.min(1.9, getAssetAspectRatio(asset)));
        const w = 240;
        const h = w / ratio;
        const idx = doc.nodes.length;
        doc.nodes.push({
          id: toSwiftUUID(randomUUID()),
          kind: {
            type: 'assetRef',
            assetID: aid,
            crop: null,
            weight: 1,
            autoplayLoop: asset.mediaKind === 'animatedImage' || asset.mediaKind === 'video',
          },
          frame: {
            x: (idx % 4) * 260 + 40,
            y: Math.floor(idx / 4) * 240 + 40,
            width: w,
            height: h,
          },
          zIndex: nextZ++,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: nextOrder++,
          updatedAt: now,
        });
      }
    }

    const noteText = asTrimmedString(args.add_note);
    if (noteText) {
      const noteTitle = asTrimmedString(args.note_title) ?? 'Agent 批注';
      const nextZ = doc.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0) + 1;
      const nextOrder = doc.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), 0) + 1;
      doc.nodes.push({
        id: toSwiftUUID(randomUUID()),
        kind: { type: 'note', title: noteTitle, text: noteText, style: 'paper', fontSize: 13.5 },
        frame: { x: 40, y: 40, width: 320, height: 148 },
        zIndex: nextZ,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: nextOrder,
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

    return jsonToolOutput({
      boardID: saved.id,
      title: saved.title,
      itemCount: getBoardReferencedAssetIDs(saved).length,
      paletteHexes: saved.extractedPalette.map((c) => c.hex.toUpperCase()),
    });
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
    this.deps.events.emitLibraryChanged(
      trashed ? 'mcp.trash_assets' : 'mcp.restore_assets',
      updated.map((a) => a.id),
    );
    return jsonToolOutput({
      updatedCount: updated.length,
      trashed,
      note: 'Soft Trash only; external agents can never permanently delete assets.',
    });
  }

  // MARK: - Helpers

  private resolveBoard(args: Record<string, unknown>): MoodboardDocument | null {
    const boardID = parseUUID(args.board_id ?? args.id);
    if (boardID) return this.deps.db.getBoard(boardID);
    const title = asTrimmedString(args.title);
    if (title) return this.deps.db.findBoardByTitle(title);
    return null;
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
    const folderID = this.resolveOptionalFolderID(args, folders, folderPathByID);

    const kinds: MediaKind[] = [];
    for (const k of asStringArray(args.media_kinds) ?? []) {
      if ((MEDIA_KINDS as readonly string[]).includes(k)) {
        kinds.push(k as MediaKind);
      }
    }

    return createDefaultFilterCriteria({
      searchQuery: query,
      kinds,
      selectedColorHex: colorHex,
      colorTolerance,
      minRating,
      tags,
      folderID: onlyInbox ? null : folderID,
      onlyInbox,
      onlyUntagged,
      sortBy: 'newest',
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

  // MARK: - All 14 MCP Tool Definitions

  static mcpToolDefinitions(): Array<Record<string, unknown>> {
    const tool = (
      name: string,
      description: string,
      properties: Record<string, unknown>,
      required: string[] = [],
      readOnly = true,
    ): Record<string, unknown> => ({
      name,
      description,
      inputSchema: {
        type: 'object',
        properties,
        ...(required.length > 0 ? { required } : {}),
      },
      annotations: {
        readOnlyHint: readOnly,
        destructiveHint: false,
      },
    });

    return [
      tool(
        'library_overview',
        'Get an overview of the Charkle visual reference library: total assets, inbox count, folder tree with IDs/paths, top tags, media distribution, board count, and active external agent permission level.',
        {},
        [],
        true,
      ),
      tool(
        'search_assets',
        'Search assets in Charkle by text query (supports Chinese, Pinyin, tags, OCR, AI descriptions), folder path/ID, tags, CIELAB dominant color hex, media kind, or rating.',
        {
          query: { type: 'string', description: 'Full-text search query across titles, notes, tags, OCR, and AI descriptions.' },
          folder_id: { type: 'string', description: 'Optional folder UUID.' },
          folder_path: { type: 'string', description: "Optional folder path or name, e.g. 'UI Inspiration'." },
          tags: { type: 'array', items: { type: 'string' }, description: 'Filter assets having all given tags.' },
          color_hex: { type: 'string', description: "Dominant color hex filter such as '#C86D51'." },
          color_tolerance: { type: 'number', description: 'CIELAB DeltaE tolerance (default 28).' },
          min_rating: { type: 'integer', description: 'Minimum star rating (0-5).' },
          only_inbox: { type: 'boolean', description: 'Only return untriaged Inbox assets.' },
          only_untagged: { type: 'boolean', description: 'Only return assets with no tags.' },
          media_kinds: { type: 'array', items: { type: 'string' }, description: 'Optional MediaKind filters.' },
          limit: { type: 'integer', description: 'Max items to return (1-100, default 30).' },
        },
        [],
        true,
      ),
      tool(
        'list_inbox',
        "List untriaged assets currently in Charkle's Inbox.",
        { limit: { type: 'integer', description: 'Max items to return (default 40).' } },
        [],
        true,
      ),
      tool(
        'get_asset',
        'Get complete metadata, OCR text, palette, tags, notes, thumbnail path, and local original path for a single asset UUID.',
        { asset_id: { type: 'string', description: 'Asset UUID.' } },
        ['asset_id'],
        true,
      ),
      tool(
        'render_contact_sheet',
        'Render up to 16 candidate assets into a numbered Visual Contact Sheet JPEG (#01..#16) returned as an image plus grounded slot-to-assetID JSON manifest.',
        {
          asset_ids: { type: 'array', items: { type: 'string' }, description: 'Explicit asset UUIDs to render (up to 16).' },
          query: { type: 'string', description: 'Search query when asset_ids is omitted.' },
          folder_path: { type: 'string', description: 'Optional folder path filter.' },
          only_inbox: { type: 'boolean', description: 'Render current Inbox assets.' },
          only_untagged: { type: 'boolean', description: 'Render untagged assets.' },
          color_hex: { type: 'string', description: 'Optional color hex filter.' },
          limit: { type: 'integer', description: 'Number of tiles (1-16, default 16).' },
          output_path: { type: 'string', description: 'Optional local path to also write the JPEG file.' },
        },
        [],
        true,
      ),
      tool(
        'list_boards',
        'List all Moodboards in Charkle with ID, title, subtitle, layout mode, item count, and extracted palette HEX codes.',
        {},
        [],
        true,
      ),
      tool(
        'get_board_context',
        'Read full structured design context of a Moodboard (title, subtitle, curator notes, section groups, harmonized HEX/CIELAB palette, and referenced assets with paths).',
        {
          board_id: { type: 'string', description: 'Moodboard UUID.' },
          title: { type: 'string', description: 'Moodboard title lookup when board_id is omitted.' },
        },
        [],
        true,
      ),
      tool(
        'export_board_image',
        'Render a Moodboard headlessly to PNG and return the image directly (optionally saving to output_path).',
        {
          board_id: { type: 'string', description: 'Moodboard UUID.' },
          title: { type: 'string', description: 'Moodboard title lookup when board_id is omitted.' },
          width: { type: 'integer', description: 'Canvas width in pixels (default 1440).' },
          dark_appearance: { type: 'boolean', description: 'Render in dark studio theme (default false).' },
          output_path: { type: 'string', description: 'Optional path to write the PNG file.' },
        },
        [],
        true,
      ),
      tool(
        'organize_assets',
        'Batch-organize assets: move to a folder or Inbox, add/remove tags, set rating, notes, title, or AI description. Requires write permission in Charkle Settings.',
        {
          asset_ids: { type: 'array', items: { type: 'string' }, description: 'Asset UUIDs to update.' },
          folder_id: { type: 'string', description: 'Move assets to this folder UUID.' },
          folder_path: { type: 'string', description: 'Move assets to this folder path/name.' },
          move_to_inbox: { type: 'boolean', description: 'Move assets back to Inbox.' },
          add_tags: { type: 'array', items: { type: 'string' }, description: 'Tags to add.' },
          remove_tags: { type: 'array', items: { type: 'string' }, description: 'Tags to remove.' },
          rating: { type: 'integer', description: 'Star rating 0-5.' },
          title: { type: 'string', description: 'Set title.' },
          notes: { type: 'string', description: 'Set notes.' },
          ai_description: { type: 'string', description: 'Save a visual description for these assets.' },
          accept_suggested_tags: { type: 'boolean', description: 'Accept AI suggested tags.' },
        },
        ['asset_ids'],
        false,
      ),
      tool(
        'create_folder',
        'Create a new folder in Charkle (optionally nested under parent_id or parent_path). Requires write permission.',
        {
          name: { type: 'string', description: 'New folder name.' },
          parent_id: { type: 'string', description: 'Optional parent folder UUID.' },
          parent_path: { type: 'string', description: 'Optional parent folder path.' },
        },
        ['name'],
        false,
      ),
      tool(
        'ingest_asset',
        'Import a local image/media file, a web URL (including X/Twitter/Threads/Bluesky/GitHub), or a text snippet into Charkle. Requires write permission.',
        {
          file_path: { type: 'string', description: 'Local file path to import.' },
          web_url: { type: 'string', description: 'Web or social/GitHub URL to capture.' },
          text: { type: 'string', description: 'Text snippet to save as a reference card.' },
          title: { type: 'string', description: 'Optional title for web_url or text.' },
          folder_path: { type: 'string', description: 'Optional destination folder path (defaults to Inbox).' },
          folder_id: { type: 'string', description: 'Optional destination folder UUID.' },
          tags: { type: 'array', items: { type: 'string' }, description: 'Optional initial tags.' },
        },
        [],
        false,
      ),
      tool(
        'compose_moodboard',
        "Create and save a new Moodboard in Charkle. Pass explicit `sections` / `asset_ids` for direct art direction, or `prompt` to invoke Charkle's Moodboard Agent Harness. Requires write permission.",
        {
          title: { type: 'string', description: 'Moodboard title.' },
          subtitle: { type: 'string', description: 'Short subtitle.' },
          curator_note: { type: 'string', description: 'Art direction note card shown on the moodboard.' },
          layout_style: { type: 'string', enum: ['magazine', 'balanced', 'compact'], description: 'Editorial layout rhythm.' },
          use_freeform: { type: 'boolean', description: 'Use freeform spatial canvas instead of Auto Editorial.' },
          sections: {
            type: 'array',
            description: 'Explicit curated sections with asset_ids and optional hero_asset_ids.',
            items: {
              type: 'object',
              properties: {
                title: { type: 'string' },
                tint: { type: 'string', enum: ['neutral', 'sand', 'sage', 'slate', 'terracotta', 'ocean'] },
                rationale: { type: 'string' },
                asset_ids: { type: 'array', items: { type: 'string' } },
                hero_asset_ids: { type: 'array', items: { type: 'string' } },
              },
              required: ['title', 'asset_ids'],
            },
          },
          asset_ids: { type: 'array', items: { type: 'string' }, description: 'Flat list of asset UUIDs if not specifying sections.' },
          hero_asset_ids: { type: 'array', items: { type: 'string' }, description: 'Optional hero asset UUIDs (weight=2).' },
          prompt: { type: 'string', description: "Natural-language brief when delegating curation to Charkle's harness." },
          folder_path: { type: 'string', description: 'Optional scope folder when using prompt mode.' },
          preferred_count: { type: 'integer', description: 'Max assets when using prompt mode (default 12).' },
        },
        [],
        false,
      ),
      tool(
        'patch_moodboard',
        'Modify an existing Moodboard (rename, add/remove asset cards while respecting locked cards, or append a curator note). Requires write permission.',
        {
          board_id: { type: 'string', description: 'Target Moodboard UUID.' },
          title: { type: 'string', description: 'Existing board title lookup if board_id is omitted.' },
          new_title: { type: 'string', description: 'Optional new title.' },
          subtitle: { type: 'string', description: 'Optional updated subtitle.' },
          add_asset_ids: { type: 'array', items: { type: 'string' }, description: 'Asset UUIDs to append.' },
          remove_asset_ids: { type: 'array', items: { type: 'string' }, description: 'Unlocked asset UUIDs to remove.' },
          add_note: { type: 'string', description: 'Append a note card to the board.' },
          note_title: { type: 'string', description: 'Title for the appended note card.' },
        },
        [],
        false,
      ),
      tool(
        'trash_assets',
        'Soft-move assets to Trash (or restore with trashed=false). External agents are NEVER allowed to permanently delete user assets. Requires write permission.',
        {
          asset_ids: { type: 'array', items: { type: 'string' }, description: 'Asset UUIDs to move to or restore from Trash.' },
          trashed: { type: 'boolean', description: 'true to move to Trash (default), false to restore.' },
        },
        ['asset_ids'],
        false,
      ),
    ];
  }
}
