import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import sharp from 'sharp';
import { afterEach, describe, expect, it } from 'vitest';
import {
  createDefaultExternalAgentConfig,
  createDefaultSmartFolderRule,
  toSwiftUUID,
  type CharkleSSEEvent,
  type ExternalAgentDiagnosticsResponse,
} from '@charkle/shared';
import { createApp, createServerContext } from '../src/app.js';
import { ExternalAgentService } from '../src/agent/external-agent-service.js';
import { MCPStdioFrameParser } from '../src/mcp/stdio-frame-parser.js';
import { runStdioMCPServer } from '../src/mcp-stdio.js';

const tempDirs: string[] = [];

function createTempDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-ai-mcp-'));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

async function makePNG(r: number, g: number, b: number): Promise<Buffer> {
  return sharp({ create: { width: 240, height: 180, channels: 3, background: { r, g, b } } })
    .png()
    .toBuffer();
}

describe('ExternalAgentService MCP v2 (20 Safe Tools · 6 Resources · 4 Prompts · Batch · Framing)', () => {
  it('enforces independent mcp/cli channel policy and executes all 20 tools, 6 resources, 4 prompts, batch JSON-RPC & diagnostics', async () => {
    const dir = createTempDir();
    const ctx = createServerContext({ dataDir: dir });
    const app = createApp(ctx, { staticClientDir: null });

    const user = await ctx.auth.setupAdmin('admin', 'strong-password-123');
    const pat = ctx.auth.createApiToken(user.id, 'mcp-pat', ['read', 'write', 'mcp']);

    const capturedEvents: CharkleSSEEvent[] = [];
    ctx.events.subscribe((e) => capturedEvents.push(e));

    // Seed three real images in Inbox + a smart folder
    const id1 = toSwiftUUID('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01');
    const id2 = toSwiftUUID('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02');
    const id3 = toSwiftUUID('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa03');
    const r1 = await ctx.media.ingestUploadedFile(await makePNG(186, 107, 85), 'terracotta.png', 'image/png', null, id1);
    const r2 = await ctx.media.ingestUploadedFile(await makePNG(180, 102, 80), 'terracotta-alt.png', 'image/png', null, id2);
    const r3 = await ctx.media.ingestUploadedFile(await makePNG(78, 125, 150), 'ocean-blue.png', 'image/png', null, id3);
    ctx.db.saveAssetLocally({ ...r1.asset, title: 'Terracotta Wall', tags: ['warm', 'minimal'], rating: 5 });
    ctx.db.saveAssetLocally({ ...r2.asset, title: 'Terracotta Plaster', tags: ['warm'], rating: 4 });
    ctx.db.saveAssetLocally({ ...r3.asset, title: 'Ocean Study', tags: ['ocean'], rating: 4 });
    if (r1.vector) ctx.db.saveVector(id1, r1.vector);
    if (r2.vector) ctx.db.saveVector(id2, r2.vector);
    if (r3.vector) ctx.db.saveVector(id3, r3.vector);

    const sf = ctx.db.saveSmartFolder({
      id: toSwiftUUID('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb01'),
      name: 'Five Star Picks',
      colorHex: '#2A60E0',
      rule: createDefaultSmartFolderRule({ minRating: 5 }),
      sortOrder: 0,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    });

    const rpcRaw = async (body: unknown) => {
      const res = await app.request('/api/v1/mcp', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${pat.token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
      });
      if (res.status === 204) return null;
      expect(res.status).toBe(200);
      return (await res.json()) as unknown;
    };

    const rpc = async (method: string, params?: Record<string, unknown>, id: number | null = 1) => {
      const payload: Record<string, unknown> = { jsonrpc: '2.0', method };
      if (id !== null) payload.id = id;
      if (params !== undefined) payload.params = params;
      return (await rpcRaw(payload)) as {
        result?: Record<string, unknown>;
        error?: { code: number; message: string };
      } | null;
    };

    const callTool = async (name: string, args: Record<string, unknown> = {}) => {
      const res = await rpc('tools/call', { name, arguments: args });
      return res!.result as {
        content: Array<{ type: string; text?: string; mimeType?: string; data?: string }>;
        isError: boolean;
      };
    };

    // 1. Protocol version negotiation & capabilities
    const initNew = await rpc('initialize', { protocolVersion: '2025-11-25' });
    expect(initNew!.result!.protocolVersion).toBe('2025-11-25');
    expect((initNew!.result!.serverInfo as { version: string }).version).toBe('1.0.1');
    expect(initNew!.result!.capabilities).toMatchObject({
      tools: { listChanged: false },
      resources: { subscribe: false, listChanged: false },
      prompts: { listChanged: false },
      logging: {},
    });

    const initFallback = await rpc('initialize', { protocolVersion: '1999-01-01' });
    expect(initFallback!.result!.protocolVersion).toBe('2025-03-26');

    expect(await rpc('notifications/initialized', {}, null)).toBeNull();
    expect((await rpc('ping'))!.result).toEqual({});
    expect((await rpc('logging/setLevel', { level: 'info' }))!.result).toEqual({});

    // 2. Exact 20 safe tools (12 Read + 8 Write), ZERO destructive / permanent delete tools
    const listedTools = await rpc('tools/list');
    const tools = listedTools!.result!.tools as Array<{
      name: string;
      annotations: { readOnlyHint: boolean; destructiveHint: boolean; title: string };
    }>;
    expect(tools).toHaveLength(20);
    expect(tools.filter((t) => t.annotations.readOnlyHint)).toHaveLength(12);
    expect(tools.filter((t) => !t.annotations.readOnlyHint)).toHaveLength(8);
    expect(tools.every((t) => t.annotations.destructiveHint === false)).toBe(true);
    expect(tools.some((t) => t.name.includes('delete') || t.name.includes('remove'))).toBe(false);

    // 3. All 4 static resources + 2 dynamic templates + 4 prompts
    const listedResources = await rpc('resources/list');
    const resources = listedResources!.result!.resources as Array<{ uri: string }>;
    expect(resources.map((r) => r.uri)).toEqual([
      'charkle://library/overview',
      'charkle://boards',
      'charkle://folders',
      'charkle://smart-folders',
    ]);

    const listedTemplates = await rpc('resources/templates/list');
    const templates = listedTemplates!.result!.resourceTemplates as Array<{ uriTemplate: string }>;
    expect(templates.map((t) => t.uriTemplate)).toEqual([
      'charkle://assets/{asset_id}',
      'charkle://boards/{board_id}',
    ]);

    const listedPrompts = await rpc('prompts/list');
    const prompts = listedPrompts!.result!.prompts as Array<{ name: string }>;
    expect(prompts.map((p) => p.name)).toEqual([
      'triage_inbox',
      'curate_moodboard',
      'extract_design_tokens',
      'inspect_ai_prompts',
    ]);

    for (const pName of ['triage_inbox', 'curate_moodboard', 'extract_design_tokens', 'inspect_ai_prompts']) {
      const rendered = await rpc('prompts/get', {
        name: pName,
        arguments: { brief: 'Warm concrete', board: 'Test Board', query: 'flux' },
      });
      expect(rendered!.error).toBeUndefined();
      expect((rendered!.result!.messages as unknown[]).length).toBeGreaterThan(0);
    }

    // 4. JSON-RPC 2.0 batch array support (mixed + notification-only + empty batch)
    const batchResp = (await rpcRaw([
      { jsonrpc: '2.0', id: 10, method: 'ping' },
      { jsonrpc: '2.0', method: 'notifications/initialized' },
      { jsonrpc: '2.0', id: 11, method: 'prompts/list' },
    ])) as Array<{ id: number; result?: unknown }>;
    expect(Array.isArray(batchResp)).toBe(true);
    expect(batchResp).toHaveLength(2);
    expect(batchResp[0].id).toBe(10);
    expect(batchResp[1].id).toBe(11);

    const notifOnlyBatch = await rpcRaw([{ jsonrpc: '2.0', method: 'notifications/initialized' }]);
    expect(notifOnlyBatch).toBeNull();

    const emptyBatch = (await rpcRaw([])) as { error?: { code: number } };
    expect(emptyBatch.error?.code).toBe(-32600);

    // 5. Independent mcpEnabled / cliEnabled toggles + readOnly enforcement
    const blockedWrite = await callTool('create_folder', { name: 'Blocked' });
    expect(blockedWrite.isError).toBe(true);
    expect(blockedWrite.content[0].text).toContain('仅只读');

    // Disable MCP only while keeping CLI enabled -> HTTP MCP rejects with -32001, direct CLI channel succeeds!
    ctx.configStore.setExternalAgentConfig(
      createDefaultExternalAgentConfig({
        mcpEnabled: false,
        cliEnabled: true,
        accessLevel: 'readWriteOrganize',
      }),
    );
    expect((await rpc('initialize', {}))!.error?.code).toBe(-32001);
    expect((await rpc('tools/list'))!.error?.code).toBe(-32001);
    expect((await callTool('library_overview')).isError).toBe(true);

    const directSvc = new ExternalAgentService({
      db: ctx.db,
      media: ctx.media,
      configStore: ctx.configStore,
      events: ctx.events,
    });
    const cliAllowed = await directSvc.callTool('library_overview', {}, 'cli');
    expect(cliAllowed.isError).toBe(false);
    const mcpBlocked = await directSvc.callTool('library_overview', {}, 'mcp');
    expect(mcpBlocked.isError).toBe(true);

    // Enable both + readWriteOrganize -> test all 20 tools!
    ctx.configStore.setExternalAgentConfig(
      createDefaultExternalAgentConfig({
        mcpEnabled: true,
        cliEnabled: true,
        accessLevel: 'readWriteOrganize',
      }),
    );

    // GET /api/v1/agent/diagnostics
    const diagRes = await app.request('/api/v1/agent/diagnostics', {
      headers: { Authorization: `Bearer ${pat.token}` },
    });
    expect(diagRes.status).toBe(200);
    const diag = (await diagRes.json()) as ExternalAgentDiagnosticsResponse;
    expect(diag.ok).toBe(true);
    expect(diag.serverVersion).toBe('1.0.1');
    expect(diag.capabilities).toMatchObject({
      toolCount: 20,
      readToolCount: 12,
      writeToolCount: 8,
      resourceCount: 4,
      resourceTemplateCount: 2,
      promptCount: 4,
      permanentDeleteAllowed: false,
    });
    expect(diag.library.totalAssets).toBe(3);
    expect(diag.library.smartFolderCount).toBe(1);

    // Read 1: library_overview
    const overview = JSON.parse((await callTool('library_overview')).content[0].text!);
    expect(overview.totalAssets).toBe(3);
    expect(overview.smartFolders).toHaveLength(1);
    expect(overview.canWrite).toBe(true);

    // Read 2: search_assets (pagination + smart folder filter)
    const searchPage = JSON.parse((await callTool('search_assets', { limit: 2, offset: 0 })).content[0].text!);
    expect(searchPage.totalMatched).toBe(3);
    expect(searchPage.hasMore).toBe(true);
    expect(searchPage.nextOffset).toBe(2);

    const sfSearch = JSON.parse((await callTool('search_assets', { smart_folder_id: sf.id })).content[0].text!);
    expect(sfSearch.totalMatched).toBe(1);
    expect(sfSearch.assets[0].id).toBe(id1);

    // Read 3: list_inbox (paginated)
    const inboxOut = JSON.parse((await callTool('list_inbox', { limit: 2, offset: 1 })).content[0].text!);
    expect(inboxOut.inboxTotal).toBe(3);
    expect(inboxOut.returned).toBe(2);

    // Read 4: get_asset (with include_image: true)
    const getAssetOut = await callTool('get_asset', { asset_id: id1, include_image: true, image_max_side: 400 });
    expect(getAssetOut.isError).toBe(false);
    expect(getAssetOut.content).toHaveLength(2);
    expect(getAssetOut.content[0].type).toBe('image');
    expect(JSON.parse(getAssetOut.content[1].text!).title).toBe('Terracotta Wall');

    // Read 5: render_contact_sheet (with max_width & pagination)
    const sheetOut = await callTool('render_contact_sheet', { asset_ids: [id1, id2], max_width: 960 });
    expect(sheetOut.isError).toBe(false);
    expect(sheetOut.content[0].type).toBe('image');
    expect(JSON.parse(sheetOut.content[1].text!).slotCount).toBe(2);

    // Read 6: find_similar_assets (with optional contact sheet)
    const similarOut = await callTool('find_similar_assets', {
      asset_id: id1,
      limit: 5,
      render_contact_sheet: true,
    });
    expect(similarOut.isError).toBe(false);
    const similarJson = JSON.parse(similarOut.content.find((c) => c.type === 'text')!.text!);
    expect(similarJson.referenceAssetID).toBe(id1);
    expect(similarJson.returned).toBeGreaterThanOrEqual(1);

    // Read 7: semantic_search
    const semanticOut = JSON.parse(
      (await callTool('semantic_search', { query: 'Terracotta', limit: 10 })).content[0].text!,
    );
    expect(semanticOut.returned).toBeGreaterThanOrEqual(1);
    expect(semanticOut.hits[0].title).toContain('Terracotta');

    // Read 8: quick_jump
    const jumpOut = JSON.parse((await callTool('quick_jump', { query: 'Ocean', limit: 10 })).content[0].text!);
    expect(jumpOut.returned).toBeGreaterThanOrEqual(1);

    // Write 13 & 14: create_folder (with appearance) + update_folder (rename, move, appearance)
    const parentFolder = JSON.parse(
      (await callTool('create_folder', { name: 'Archive', color_hex: '#2A60E0' })).content[0].text!,
    );
    const childFolder = JSON.parse(
      (await callTool('create_folder', { name: 'Materials', parent_id: parentFolder.id })).content[0].text!,
    );
    expect(childFolder.path).toBe('Archive/Materials');

    const updatedFolder = JSON.parse(
      (
        await callTool('update_folder', {
          folder_id: childFolder.id,
          new_name: 'Textures',
          move_to_root: true,
          color_hex: '#BA6B55',
        })
      ).content[0].text!,
    );
    expect(updatedFolder.name).toBe('Textures');
    expect(updatedFolder.path).toBe('Textures');
    expect(updatedFolder.parentID).toBe('');
    expect(updatedFolder.colorHex).toBe('#BA6B55');

    // Write 15: organize_assets (explicit ai_description overwrite + pinned_offline + skippedIDs)
    const missingUUID = toSwiftUUID('ffffffff-ffff-4fff-8fff-ffffffffffff');
    const orgOut = JSON.parse(
      (
        await callTool('organize_assets', {
          asset_ids: [id1, missingUUID],
          folder_path: 'Textures',
          add_tags: ['curated'],
          ai_description: '初始描述',
          pinned_offline: true,
        })
      ).content[0].text!,
    );
    expect(orgOut.updatedCount).toBe(1);
    expect(orgOut.skippedIDs).toEqual([missingUUID]);
    expect(ctx.db.getAsset(id1)!.pinnedOffline).toBe(true);
    expect(ctx.db.getAsset(id1)!.aiDescription).toBe('初始描述');

    // Verify explicit overwrite of existing ai_description
    await callTool('organize_assets', { asset_ids: [id1], ai_description: '暖陶肌理墙面' });
    expect(ctx.db.getAsset(id1)!.aiDescription).toBe('暖陶肌理墙面');

    // Read 9: suggest_folder (id2 is visually similar to id1 in Textures!)
    const suggestOut = JSON.parse(
      (await callTool('suggest_folder', { asset_ids: [id2, missingUUID] })).content[0].text!,
    );
    expect(suggestOut.evaluatedCount).toBe(2);
    expect(suggestOut.recommendations[1].found).toBe(false);

    // Write 16: ingest_asset (text snippet + rating + notes + tags)
    const ingestTextOut = JSON.parse(
      (
        await callTool('ingest_asset', {
          text: 'Warm terracotta paired with cool slate stone.',
          title: 'Color Direction Note',
          folder_path: 'Textures',
          tags: ['note'],
          rating: 5,
          notes: 'Imported by MCP',
        })
      ).content[0].text!,
    );
    const ingestedId = ingestTextOut.assets[0].id as string;
    expect(ctx.db.getAsset(ingestedId)!.rating).toBe(5);
    expect(ctx.db.getAsset(ingestedId)!.notes).toBe('Imported by MCP');

    // Write 17: compose_moodboard
    const composeOut = JSON.parse(
      (
        await callTool('compose_moodboard', {
          title: 'MCP Curated Board',
          subtitle: 'Built by Agent',
          curator_note: '聚焦陶土与海蓝的冷暖碰撞。',
          sections: [{ title: '冷暖主视觉', tint: 'sand', asset_ids: [id1, id2], hero_asset_ids: [id1] }],
        })
      ).content[0].text!,
    );
    const boardID = composeOut.boardID as string;

    // Lock id1 on board
    const doc = ctx.db.getBoard(boardID)!;
    const prevMaxY = doc.nodes.reduce((m, n) => Math.max(m, n.frame.y + n.frame.height), 0);
    ctx.db.saveBoardLocally({
      ...doc,
      nodes: doc.nodes.map((n) =>
        n.kind.type === 'assetRef' && n.kind.assetID === id1 ? { ...n, isLocked: true } : n,
      ),
    });

    // Read 10, 11, 12: list_boards, get_board_context, export_board_image
    expect(JSON.parse((await callTool('list_boards')).content[0].text!).count).toBe(1);
    const boardCtx = JSON.parse((await callTool('get_board_context', { board_id: boardID })).content[0].text!);
    expect(boardCtx.title).toBe('MCP Curated Board');
    expect(boardCtx.assets).toHaveLength(2);
    expect(Array.isArray(boardCtx.connectors)).toBe(true);

    const exportImgOut = await callTool('export_board_image', { board_id: boardID, width: 1000 });
    expect(exportImgOut.isError).toBe(false);
    expect(exportImgOut.content[0].type).toBe('image');

    // Write 18: patch_moodboard (non-overlapping placement >= prevMaxY + 24, add_section, note_style, skippedLocked)
    const patchOut = JSON.parse(
      (
        await callTool('patch_moodboard', {
          board_id: boardID,
          new_title: 'MCP Refined Board',
          remove_asset_ids: [id1, id2],
          add_section: '新增配色分区',
          section_tint: 'terracotta',
          add_asset_ids: [ingestedId, missingUUID],
          add_note: '补充对比说明',
          note_title: '修订记录',
          note_style: 'warm',
        })
      ).content[0].text!,
    );
    expect(patchOut.skippedLockedAssetIDs).toEqual([id1]);
    expect(patchOut.skippedMissingAssetIDs).toEqual([missingUUID]);
    expect(patchOut.addedCount).toBe(1);
    expect(patchOut.removedCount).toBe(1);

    const patchedDoc = ctx.db.getBoard(boardID)!;
    const addedSection = patchedDoc.nodes.find(
      (n) => n.kind.type === 'groupFrame' && n.kind.title === '新增配色分区',
    );
    expect(addedSection).toBeDefined();
    expect(addedSection!.frame.y).toBeGreaterThanOrEqual(prevMaxY + 24);

    // Write 19: trash_assets (soft trash + restore)
    const trashOut = JSON.parse((await callTool('trash_assets', { asset_ids: [id2], trashed: true })).content[0].text!);
    expect(trashOut.trashed).toBe(true);
    expect(ctx.db.getAsset(id2)!.isTrashed).toBe(true);
    await callTool('trash_assets', { asset_ids: [id2], trashed: false });
    expect(ctx.db.getAsset(id2)!.isTrashed).toBe(false);

    // Write 20: analyze_assets
    const analyzeOut = JSON.parse((await callTool('analyze_assets', { asset_ids: [id1, id3] })).content[0].text!);
    expect(analyzeOut.analyzedCount).toBe(2);

    // Read all 6 resource URIs (4 static + 2 dynamic templates)
    for (const uri of [
      'charkle://library/overview',
      'charkle://boards',
      'charkle://folders',
      'charkle://smart-folders',
      `charkle://assets/${id1}`,
      `charkle://boards/${boardID}`,
    ]) {
      const readRes = await rpc('resources/read', { uri });
      expect(readRes!.error).toBeUndefined();
      const contents = readRes!.result!.contents as Array<{ uri: string; mimeType: string; text: string }>;
      expect(contents[0].uri).toBe(uri);
      expect(contents[0].mimeType).toBe('application/json');
      expect(() => JSON.parse(contents[0].text)).not.toThrow();
    }

    expect(capturedEvents.some((e) => e.type === 'library.changed')).toBe(true);
    expect(capturedEvents.some((e) => e.type === 'board.updated')).toBe(true);
    expect(ExternalAgentService.mcpToolDefinitions()).toHaveLength(20);

    ctx.db.close();
  });

  it('parses split-chunk Content-Length and NDJSON streams cleanly via MCPStdioFrameParser and runStdioMCPServer', async () => {
    // 1. Direct unit test of MCPStdioFrameParser across arbitrary split chunks
    const parser = new MCPStdioFrameParser();
    const enc = new TextEncoder();
    const dec = new TextDecoder();

    const body1 = enc.encode(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }));
    const framed1 = MCPStdioFrameParser.encode(body1, 'contentLength');
    // Feed Content-Length header + body in tiny 3-byte slices to prove split-header safety!
    const events1 = [];
    for (let i = 0; i < framed1.byteLength; i += 3) {
      events1.push(...parser.append(framed1.subarray(i, Math.min(framed1.byteLength, i + 3))));
    }
    expect(events1).toHaveLength(1);
    expect(events1[0].type).toBe('message');
    if (events1[0].type === 'message') {
      expect(events1[0].framing).toBe('contentLength');
      expect(dec.decode(events1[0].payload)).toBe(dec.decode(body1));
    }

    // Feed NDJSON batch array + \n\n Content-Length fallback
    const ndjsonBatch = enc.encode('[{"jsonrpc":"2.0","id":2,"method":"ping"}]\n');
    const lfHeaderBody = enc.encode('{"jsonrpc":"2.0","id":3,"method":"ping"}');
    const lfFrame = new Uint8Array([
      ...enc.encode(`Content-Length: ${lfHeaderBody.byteLength}\n\n`),
      ...lfHeaderBody,
    ]);
    const events2 = [...parser.append(ndjsonBatch), ...parser.append(lfFrame), ...parser.finishEOF()];
    expect(events2).toHaveLength(2);
    expect(events2[0].type === 'message' && events2[0].framing).toBe('ndjson');
    expect(events2[1].type === 'message' && events2[1].framing).toBe('contentLength');

    // 2. End-to-end runStdioMCPServer over BOTH NDJSON and Content-Length framing!
    const dir = createTempDir();
    const input = new PassThrough();
    const output = new PassThrough();
    const outChunks: Buffer[] = [];
    output.on('data', (chunk: Buffer) => outChunks.push(Buffer.from(chunk)));

    const serverPromise = runStdioMCPServer({ dataDir: dir, input, output });

    // Send 1 Content-Length framed request split across chunks, 1 notification, and 2 NDJSON requests
    const initBody = enc.encode(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }));
    const initFrame = MCPStdioFrameParser.encode(initBody, 'contentLength');
    input.write(initFrame.subarray(0, 10));
    input.write(initFrame.subarray(10));
    input.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`);
    input.write(`${JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' })}\n`);
    input.write(`${JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'library_overview', arguments: {} } })}\n`);
    input.end();

    await serverPromise;

    const outParser = new MCPStdioFrameParser();
    const outEvents = [
      ...outParser.append(Buffer.concat(outChunks)),
      ...outParser.finishEOF(),
    ];
    expect(outEvents).toHaveLength(3);
    // Reply 1 matches Content-Length framing!
    expect(outEvents[0].type).toBe('message');
    if (outEvents[0].type === 'message') {
      expect(outEvents[0].framing).toBe('contentLength');
      const r0 = JSON.parse(dec.decode(outEvents[0].payload)) as { id: number; result: { serverInfo: { name: string } } };
      expect(r0.id).toBe(1);
      expect(r0.result.serverInfo.name).toBe('charkle');
    }
    // Reply 2 & 3 match NDJSON framing!
    if (outEvents[1].type === 'message') {
      expect(outEvents[1].framing).toBe('ndjson');
      const r1 = JSON.parse(dec.decode(outEvents[1].payload)) as { id: number; result: { tools: unknown[] } };
      expect(r1.id).toBe(2);
      expect(r1.result.tools).toHaveLength(20);
    }
    if (outEvents[2].type === 'message') {
      expect(outEvents[2].framing).toBe('ndjson');
      const r2 = JSON.parse(dec.decode(outEvents[2].payload)) as { id: number; result: { isError: boolean } };
      expect(r2.id).toBe(3);
      expect(r2.result.isError).toBe(false);
    }
  });
});
