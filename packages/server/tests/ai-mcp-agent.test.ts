import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import sharp from 'sharp';
import { afterEach, describe, expect, it } from 'vitest';
import { toSwiftUUID, type CharkleSSEEvent } from '@charkle/shared';
import { createApp, createServerContext } from '../src/app.js';
import { ExternalAgentService } from '../src/agent/external-agent-service.js';
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

describe('ExternalAgentService & 14-Tool MCP Server (HTTP + stdio)', () => {
  it('enforces policy levels dynamically and executes all 14 MCP tools + 2 resources + SSE write notifications', async () => {
    const dir = createTempDir();
    const ctx = createServerContext({ dataDir: dir });
    const app = createApp(ctx, { staticClientDir: null });

    const user = ctx.auth.setupAdmin('admin', 'strong-password-123');
    const pat = ctx.auth.createApiToken(user.id, 'mcp-pat', ['read', 'write', 'mcp']);

    const capturedEvents: CharkleSSEEvent[] = [];
    ctx.events.subscribe((e) => capturedEvents.push(e));

    // Seed two real images in Inbox
    const id1 = toSwiftUUID('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01');
    const id2 = toSwiftUUID('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02');
    const r1 = await ctx.media.ingestUploadedFile(await makePNG(186, 107, 85), 'terracotta.png', 'image/png', null, id1);
    const r2 = await ctx.media.ingestUploadedFile(await makePNG(78, 125, 150), 'ocean-blue.png', 'image/png', null, id2);
    ctx.db.saveAssetLocally({ ...r1.asset, title: 'Terracotta Wall', tags: ['warm', 'minimal'], rating: 5 });
    ctx.db.saveAssetLocally({ ...r2.asset, title: 'Ocean Study', tags: ['ocean'], rating: 4 });

    const rpc = async (method: string, params?: Record<string, unknown>, id: number | null = 1) => {
      const payload: Record<string, unknown> = { jsonrpc: '2.0', method };
      if (id !== null) payload.id = id;
      if (params !== undefined) payload.params = params;
      const res = await app.request('/api/v1/mcp', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${pat.token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(payload),
      });
      if (res.status === 204) return null;
      expect(res.status).toBe(200);
      return (await res.json()) as {
        result?: Record<string, unknown>;
        error?: { code: number; message: string };
      };
    };

    const callTool = async (name: string, args: Record<string, unknown> = {}) => {
      const res = await rpc('tools/call', { name, arguments: args });
      const result = res!.result as { content: Array<{ type: string; text?: string; mimeType?: string; data?: string }>; isError: boolean };
      return result;
    };

    // Protocol methods: initialize, notification, ping, tools/list, resources/list
    const init = await rpc('initialize', { protocolVersion: '2025-03-26' });
    expect((init!.result!.serverInfo as { name: string }).name).toBe('charkle');

    const notif = await rpc('notifications/initialized', {}, null);
    expect(notif).toBeNull();

    const ping = await rpc('ping');
    expect(ping!.result).toEqual({});

    const listedTools = await rpc('tools/list');
    const tools = listedTools!.result!.tools as Array<{ name: string; annotations: { destructiveHint: boolean } }>;
    expect(tools).toHaveLength(14);
    expect(tools.every((t) => t.annotations.destructiveHint === false)).toBe(true);

    const listedResources = await rpc('resources/list');
    const resources = listedResources!.result!.resources as Array<{ uri: string }>;
    expect(resources.map((r) => r.uri)).toEqual(['charkle://library/overview', 'charkle://boards']);

    // Policy: Default is enabled + readOnly -> reads succeed, writes blocked!
    const overviewOut = await callTool('library_overview');
    expect(overviewOut.isError).toBe(false);
    const overview = JSON.parse(overviewOut.content[0].text!);
    expect(overview.totalAssets).toBe(2);
    expect(overview.inboxCount).toBe(2);
    expect(overview.canWrite).toBe(false);

    const blockedWrite = await callTool('create_folder', { name: 'Blocked' });
    expect(blockedWrite.isError).toBe(true);
    expect(blockedWrite.content[0].text).toContain('仅只读');

    // Policy: Disabled -> blocks reads AND resources/read!
    ctx.configStore.setExternalAgentConfig({ enabled: false, accessLevel: 'readWriteOrganize' });
    const disabledRead = await callTool('library_overview');
    expect(disabledRead.isError).toBe(true);
    const disabledRes = await rpc('resources/read', { uri: 'charkle://library/overview' });
    expect(disabledRes!.error?.code).toBe(-32001);

    // Policy: Enabled + readWriteOrganize -> all 14 tools work!
    ctx.configStore.setExternalAgentConfig({ enabled: true, accessLevel: 'readWriteOrganize' });

    // Read 2: search_assets
    const searchOut = await callTool('search_assets', { query: 'Terracotta', min_rating: 4 });
    expect(searchOut.isError).toBe(false);
    expect(JSON.parse(searchOut.content[0].text!).totalMatched).toBe(1);

    // Read 3: list_inbox
    const inboxOut = await callTool('list_inbox', { limit: 10 });
    expect(JSON.parse(inboxOut.content[0].text!).inboxTotal).toBe(2);

    // Read 4: get_asset
    const getAssetOut = await callTool('get_asset', { asset_id: id1 });
    expect(JSON.parse(getAssetOut.content[0].text!).title).toBe('Terracotta Wall');

    // Read 5: render_contact_sheet (multimodal JPEG + JSON manifest)
    const sheetOut = await callTool('render_contact_sheet', { asset_ids: [id1, id2] });
    expect(sheetOut.isError).toBe(false);
    expect(sheetOut.content).toHaveLength(2);
    expect(sheetOut.content[0].type).toBe('image');
    expect(sheetOut.content[0].mimeType).toBe('image/jpeg');
    expect(JSON.parse(sheetOut.content[1].text!).slotCount).toBe(2);

    // Write 10: create_folder
    const createFolderOut = await callTool('create_folder', { name: 'Materials' });
    expect(createFolderOut.isError).toBe(false);
    const folderID = JSON.parse(createFolderOut.content[0].text!).id;

    // Write 9: organize_assets
    const orgOut = await callTool('organize_assets', {
      asset_ids: [id1],
      folder_path: 'Materials',
      add_tags: ['curated'],
      ai_description: '暖陶肌理墙面',
    });
    expect(orgOut.isError).toBe(false);
    expect(ctx.db.getAsset(id1)!.folderID).toBe(folderID);
    expect(ctx.db.getAsset(id1)!.tags).toContain('curated');
    expect(ctx.db.getAsset(id1)!.aiDescription).toBe('暖陶肌理墙面');

    // Write 11: ingest_asset (text snippet + file_path)
    const ingestTextOut = await callTool('ingest_asset', {
      text: 'Warm terracotta paired with cool slate stone.',
      title: 'Color Direction Note',
      folder_path: 'Materials',
      tags: ['note'],
    });
    expect(ingestTextOut.isError).toBe(false);
    const ingestedId = JSON.parse(ingestTextOut.content[0].text!).assets[0].id;
    expect(ctx.db.getAsset(ingestedId)!.tags).toContain('note');

    // Write 12: compose_moodboard (Mode A explicit sections)
    const composeOut = await callTool('compose_moodboard', {
      title: 'MCP Curated Board',
      subtitle: 'Built by Agent',
      curator_note: '聚焦陶土与海蓝的冷暖碰撞。',
      sections: [
        { title: '冷暖主视觉', tint: 'sand', asset_ids: [id1, id2], hero_asset_ids: [id1] },
      ],
    });
    expect(composeOut.isError).toBe(false);
    const boardID = JSON.parse(composeOut.content[0].text!).boardID;

    // Lock id1 on the board so patch_moodboard respects isLocked!
    const doc = ctx.db.getBoard(boardID)!;
    ctx.db.saveBoardLocally({
      ...doc,
      nodes: doc.nodes.map((n) =>
        n.kind.type === 'assetRef' && n.kind.assetID === id1 ? { ...n, isLocked: true } : n,
      ),
    });

    // Read 6: list_boards
    const listBoardsOut = await callTool('list_boards');
    expect(JSON.parse(listBoardsOut.content[0].text!).count).toBe(1);

    // Read 7: get_board_context
    const boardCtxOut = await callTool('get_board_context', { board_id: boardID });
    const boardCtx = JSON.parse(boardCtxOut.content[0].text!);
    expect(boardCtx.title).toBe('MCP Curated Board');
    expect(boardCtx.assets).toHaveLength(2);

    // Read 8: export_board_image (multimodal PNG + metadata)
    const exportImgOut = await callTool('export_board_image', { board_id: boardID, width: 1000 });
    expect(exportImgOut.isError).toBe(false);
    expect(exportImgOut.content[0].type).toBe('image');
    expect(exportImgOut.content[0].mimeType).toBe('image/png');
    expect(JSON.parse(exportImgOut.content[1].text!).bytes).toBeGreaterThan(1000);

    // Write 13: patch_moodboard (cannot remove locked id1, removes unlocked id2, adds note)
    const patchOut = await callTool('patch_moodboard', {
      board_id: boardID,
      new_title: 'MCP Refined Board',
      remove_asset_ids: [id1, id2],
      add_asset_ids: [ingestedId],
      add_note: '补充对比说明',
      note_title: '修订记录',
    });
    expect(patchOut.isError).toBe(false);
    const patchedDoc = ctx.db.getBoard(boardID)!;
    expect(patchedDoc.title).toBe('MCP Refined Board');
    const refIDs = patchedDoc.nodes
      .filter((n) => n.kind.type === 'assetRef')
      .map((n) => (n.kind.type === 'assetRef' ? n.kind.assetID : ''));
    expect(refIDs).toContain(id1); // locked -> protected!
    expect(refIDs).not.toContain(id2); // unlocked -> removed!
    expect(refIDs).toContain(ingestedId);

    // Write 14: trash_assets (soft trash + restore)
    const trashOut = await callTool('trash_assets', { asset_ids: [id2], trashed: true });
    expect(trashOut.isError).toBe(false);
    expect(ctx.db.getAsset(id2)!.isTrashed).toBe(true);
    const restoreOut = await callTool('trash_assets', { asset_ids: [id2], trashed: false });
    expect(restoreOut.isError).toBe(false);
    expect(ctx.db.getAsset(id2)!.isTrashed).toBe(false);

    // Resources read
    const resOverview = await rpc('resources/read', { uri: 'charkle://library/overview' });
    expect((resOverview!.result!.contents as Array<{ mimeType: string }>)[0].mimeType).toBe('application/json');
    const resBoards = await rpc('resources/read', { uri: 'charkle://boards' });
    expect((resBoards!.result!.contents as Array<{ text: string }>)[0].text).toContain('MCP Refined Board');

    // SSE write events emitted!
    expect(capturedEvents.some((e) => e.type === 'library.changed')).toBe(true);
    expect(capturedEvents.some((e) => e.type === 'board.updated')).toBe(true);

    // Static tool list check
    expect(ExternalAgentService.mcpToolDefinitions()).toHaveLength(14);

    ctx.db.close();
  });

  it('works over stdio transport via runStdioMCPServer', async () => {
    const dir = createTempDir();
    const input = new PassThrough();
    const output = new PassThrough();
    const chunks: string[] = [];
    output.on('data', (chunk) => chunks.push(chunk.toString('utf8')));

    const serverPromise = runStdioMCPServer({ dataDir: dir, input, output });

    input.write(`${JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })}\n`);
    input.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`);
    input.write(`${JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' })}\n`);
    input.write(`${JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'library_overview', arguments: {} } })}\n`);
    input.end();

    await serverPromise;

    const lines = chunks.join('').trim().split('\n').map((l) => JSON.parse(l) as { id: number; result: Record<string, unknown> });
    expect(lines).toHaveLength(3); // notification emits no response
    expect(lines[0].id).toBe(1);
    expect((lines[0].result.serverInfo as { name: string }).name).toBe('charkle');
    expect(lines[1].id).toBe(2);
    expect((lines[1].result.tools as unknown[]).length).toBe(14);
    expect(lines[2].id).toBe(3);
    expect((lines[2].result as { isError: boolean }).isError).toBe(false);
  });
});
