import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Context, Hono } from 'hono';
import { deleteCookie, setCookie } from 'hono/cookie';
import { streamSSE } from 'hono/streaming';
import JSZip from 'jszip';
import {
  activeStorageLocationSummary,
  createDefaultAutoLayoutConfig,
  createDefaultMoodboardDocument,
  createDefaultSmartFolderRule,
  freezeIntoFreeform,
  toSwiftUUID,
  type AssetBatchPatch,
  type AssetRecord,
  type AssetsQueryRequest,
  type AuthChangePasswordRequest,
  type AuthLoginRequest,
  type AuthSetupRequest,
  type BoardNode,
  type CreateApiTokenRequest,
  type CreateBoardRequest,
  type CreateFolderRequest,
  type ExtractSocialMediaRequest,
  type IngestRequest,
  type LabColor,
  type MigrateStorageRequest,
  type MoveFolderRequest,
  type RenameFolderRequest,
  type SaveBoardRequest,
  type SaveGoogleOAuthConfigRequest,
  type SaveSmartFolderRequest,
  type SaveSyncConfigRequest,
  type SmartFolderRecord,
  type SyncConfigResponse,
  type TestWebDAVRequest,
  type ThumbnailTier,
  type UpdateCacheBudgetRequest,
  type UpdateFolderAppearanceRequest,
  type UUID,
} from '@charkle/shared';
import { AuthError } from '../auth/auth-service.js';
import { LoginRateLimiter } from '../auth/rate-limiter.js';
import type { AuthenticatedPrincipal, ServerContext } from '../context.js';
import { seedSampleLibrary } from '../media/sample-seeder.js';
import { SECRET_KEYS } from '../storage/secret-vault.js';
import { DriveTransportError } from '../sync/drive-transport.js';
import type { DriveSyncEngine } from '../sync/drive-sync-engine.js';
import {
  getClientIP,
  isSecureRequest,
  type AppVariables,
} from './middleware-auth.js';

export interface CoreRouteOptions {
  rateLimiter?: LoginRateLimiter;
}

function requirePrincipal(c: Context<{ Variables: AppVariables }>): AuthenticatedPrincipal {
  const p = c.get('principal');
  if (!p) {
    throw new AuthError('未登录或会话已失效。', 401, 'UNAUTHORIZED');
  }
  return p;
}

function setSessionCookie(
  c: Context,
  cookieName: string,
  rawToken: string,
  expiresAtIso: string,
): void {
  setCookie(c, cookieName, rawToken, {
    httpOnly: true,
    sameSite: 'Lax',
    path: '/',
    secure: isSecureRequest(c),
    expires: new Date(expiresAtIso),
  });
}

function buildSyncConfigResponse(ctx: ServerContext): SyncConfigResponse {
  const config = ctx.configStore.getSyncConfig();
  const status = ctx.sync.getStatus();
  const hasGoogleOAuthConfig =
    ctx.secretVault.has(SECRET_KEYS.GOOGLE_OAUTH_CLIENT_ID) ||
    Boolean(process.env.CHARKLE_GOOGLE_CLIENT_ID?.trim());
  const hasWebDAVPassword = ctx.secretVault.has(SECRET_KEYS.WEBDAV_PASSWORD);
  return {
    config,
    status,
    hasGoogleOAuthConfig,
    hasWebDAVPassword,
    activeLocationSummary: activeStorageLocationSummary(config),
  };
}

function appendAssetsToBoard(
  ctx: ServerContext,
  boardID: UUID,
  assets: readonly AssetRecord[],
): void {
  const board = ctx.db.getBoard(boardID);
  if (!board || assets.length === 0) return;

  const existingIDs = new Set(
    board.nodes
      .filter((n) => n.kind.type === 'assetRef')
      .map((n) => (n.kind.type === 'assetRef' ? toSwiftUUID(n.kind.assetID) : '')),
  );
  const now = new Date().toISOString();
  let maxZ = board.nodes.reduce((m, n) => Math.max(m, n.zIndex), 0);
  let maxOrder = board.nodes.reduce((m, n) => Math.max(m, n.editorialOrder), -1);
  const newNodes: BoardNode[] = [...board.nodes];
  let added = 0;

  for (const asset of assets) {
    const uid = toSwiftUUID(asset.id);
    if (existingIDs.has(uid)) continue;
    existingIDs.add(uid);
    const ratio =
      asset.pixelWidth > 0 && asset.pixelHeight > 0
        ? Math.max(0.5, Math.min(2.2, asset.pixelWidth / asset.pixelHeight))
        : 1.25;
    const width = 280;
    const height = Math.round(width / ratio);
    maxZ += 1;
    maxOrder += 1;
    newNodes.push({
      id: toSwiftUUID(crypto.randomUUID()),
      kind: {
        type: 'assetRef',
        assetID: uid,
        crop: null,
        weight: 1,
        autoplayLoop: true,
      },
      frame: {
        x: 60 + ((newNodes.length * 44) % 420),
        y: 80 + Math.floor(newNodes.length / 4) * 320,
        width,
        height,
      },
      zIndex: maxZ,
      rotationDegrees: 0,
      flipHorizontal: false,
      flipVertical: false,
      isLocked: false,
      editorialOrder: maxOrder,
      updatedAt: now,
    });
    added++;
  }

  if (added > 0) {
    ctx.db.saveBoardLocally({ ...board, nodes: newNodes, updatedAt: now });
    ctx.events.emitBoardUpdated(board.id);
  }
}

function handleRouteError(c: Context, err: unknown) {
  if (err instanceof AuthError) {
    return c.json({ error: err.message, code: err.code }, err.statusCode as 400 | 401 | 403 | 404 | 409);
  }
  if (err instanceof DriveTransportError) {
    const status = err.code === 'UNAUTHORIZED' ? 401 : err.code === 'NOT_FOUND' ? 404 : 400;
    return c.json({ error: err.message, code: err.code }, status);
  }
  const message = err instanceof Error ? err.message : '服务器内部错误';
  return c.json({ error: message, code: 'INTERNAL_ERROR' }, 500);
}

export function registerCoreRoutes(
  app: Hono<{ Variables: AppVariables }>,
  ctx: ServerContext,
  options: CoreRouteOptions = {},
): void {
  const rateLimiter = options.rateLimiter ?? new LoginRateLimiter(10, 15 * 60 * 1000);

  // MARK: - Health (Public)

  app.get('/api/v1/health', (c) => {
    return c.json({
      ok: true,
      version: '1.0.0',
      timestamp: new Date().toISOString(),
    });
  });

  // MARK: - Auth Routes

  app.get('/api/v1/auth/status', (c) => {
    const principal = c.get('principal') ?? null;
    return c.json(ctx.auth.getAuthStatus(principal));
  });

  app.post('/api/v1/auth/setup', async (c) => {
    try {
      const body = (await c.req.json()) as Partial<AuthSetupRequest>;
      const username = String(body.username ?? '');
      const password = String(body.password ?? '');
      const displayName = typeof body.displayName === 'string' ? body.displayName : undefined;

      ctx.auth.setupAdmin(username, password, displayName);
      const loginRes = ctx.auth.login(username, password, {
        rememberMe: true,
        userAgent: c.req.header('user-agent') ?? null,
        ipAddress: getClientIP(c),
      });
      setSessionCookie(c, ctx.auth.sessionCookieName, loginRes.rawSessionToken, loginRes.expiresAt);
      const status = ctx.auth.getAuthStatus({
        user: loginRes.user,
        authType: 'session',
        sessionID: loginRes.sessionID,
      });
      return c.json({ user: loginRes.user, status }, 201);
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/auth/login', async (c) => {
    try {
      const body = (await c.req.json()) as Partial<AuthLoginRequest & { rememberMe?: boolean }>;
      const username = String(body.username ?? '').trim();
      const password = String(body.password ?? '');
      const ip = getClientIP(c);

      const rateCheck = rateLimiter.check(ip, username);
      if (!rateCheck.allowed) {
        c.header('Retry-After', String(rateCheck.retryAfterSeconds));
        return c.json(
          {
            error: `登录尝试过于频繁，请在 ${rateCheck.retryAfterSeconds} 秒后重试。`,
            code: 'RATE_LIMITED',
          },
          429,
        );
      }

      if (!ctx.auth.isInitialized()) {
        return c.json(
          { error: '尚未初始化管理员账号，请先完成首次设置。', code: 'NOT_INITIALIZED' },
          400,
        );
      }

      try {
        const loginRes = ctx.auth.login(username, password, {
          rememberMe: Boolean(body.rememberMe),
          userAgent: c.req.header('user-agent') ?? null,
          ipAddress: ip,
        });
        rateLimiter.reset(ip, username);
        setSessionCookie(c, ctx.auth.sessionCookieName, loginRes.rawSessionToken, loginRes.expiresAt);
        const status = ctx.auth.getAuthStatus({
          user: loginRes.user,
          authType: 'session',
          sessionID: loginRes.sessionID,
        });
        return c.json({ user: loginRes.user, status });
      } catch (loginErr) {
        const failRes = rateLimiter.recordFailure(ip, username);
        if (!failRes.allowed) {
          c.header('Retry-After', String(failRes.retryAfterSeconds));
          return c.json(
            {
              error: `登录失败次数过多，请在 ${failRes.retryAfterSeconds} 秒后重试。`,
              code: 'RATE_LIMITED',
            },
            429,
          );
        }
        throw loginErr;
      }
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/auth/logout', (c) => {
    const principal = requirePrincipal(c);
    if (principal.sessionID) {
      ctx.auth.logoutSession(principal.sessionID);
    }
    deleteCookie(c, ctx.auth.sessionCookieName, { path: '/' });
    return c.json({ ok: true as const });
  });

  app.post('/api/v1/auth/change-password', async (c) => {
    try {
      const principal = requirePrincipal(c);
      const body = (await c.req.json()) as Partial<AuthChangePasswordRequest>;
      ctx.auth.changePassword(
        principal.user.id,
        String(body.currentPassword ?? ''),
        String(body.newPassword ?? ''),
        principal.sessionID,
      );
      return c.json({ ok: true as const });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.get('/api/v1/auth/sessions', (c) => {
    const principal = requirePrincipal(c);
    return c.json({
      sessions: ctx.auth.listSessions(principal.user.id, principal.sessionID),
    });
  });

  app.delete('/api/v1/auth/sessions/:id', (c) => {
    const principal = requirePrincipal(c);
    const id = c.req.param('id');
    ctx.auth.revokeSession(principal.user.id, id);
    if (principal.sessionID && toSwiftUUID(principal.sessionID) === toSwiftUUID(id)) {
      deleteCookie(c, ctx.auth.sessionCookieName, { path: '/' });
    }
    return c.json({ ok: true as const });
  });

  app.post('/api/v1/auth/sessions/revoke-others', (c) => {
    const principal = requirePrincipal(c);
    ctx.auth.revokeOtherSessions(principal.user.id, principal.sessionID);
    return c.json({ ok: true as const });
  });

  app.get('/api/v1/auth/tokens', (c) => {
    const principal = requirePrincipal(c);
    return c.json({ tokens: ctx.auth.listApiTokens(principal.user.id) });
  });

  app.post('/api/v1/auth/tokens', async (c) => {
    try {
      const principal = requirePrincipal(c);
      const body = (await c.req.json()) as Partial<CreateApiTokenRequest>;
      const result = ctx.auth.createApiToken(
        principal.user.id,
        String(body.name ?? ''),
        Array.isArray(body.scopes) ? body.scopes : ['read', 'write', 'mcp'],
        body.expiresInDays ?? null,
      );
      return c.json(result, 201);
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.delete('/api/v1/auth/tokens/:id', (c) => {
    const principal = requirePrincipal(c);
    ctx.auth.revokeApiToken(principal.user.id, c.req.param('id'));
    return c.json({ ok: true as const });
  });

  // MARK: - SSE Realtime Events

  app.get('/api/v1/events', (c) => {
    requirePrincipal(c);
    return streamSSE(c, async (stream) => {
      let closed = false;
      const sendEvent = (event: { type: string; [key: string]: unknown }) => {
        if (closed) return;
        stream
          .writeSSE({
            event: event.type,
            data: JSON.stringify(event),
          })
          .catch(() => {
            closed = true;
          });
      };

      // Initial sync snapshot
      sendEvent({
        type: 'sync.status',
        status: ctx.sync.getStatus(),
        timestamp: new Date().toISOString(),
      });

      const unsubscribe = ctx.events.subscribe(sendEvent);
      const heartbeat = setInterval(() => {
        sendEvent({ type: 'ping', timestamp: new Date().toISOString() });
      }, 25_000);

      await new Promise<void>((resolve) => {
        stream.onAbort(() => {
          closed = true;
          clearInterval(heartbeat);
          unsubscribe();
          resolve();
        });
      });
    });
  });

  // MARK: - Library Bootstrap, Seed & Quick Jump

  app.get('/api/v1/library/bootstrap', (c) => {
    return c.json({
      folders: ctx.db.fetchFolders(),
      smartFolders: ctx.db.fetchSmartFolders(),
      tags: ctx.db.fetchTagCounts(),
      boards: ctx.db.fetchBoardSummaries(),
      inboxCount: ctx.db.inboxCount(),
      totalAssetCount: ctx.db.totalAssetCount(),
      untaggedCount: ctx.db.untaggedCount(),
      trashCount: ctx.db.trashCount(),
      syncStatus: ctx.sync.getStatus(),
      aiConfig: ctx.configStore.getAIConfig(),
    });
  });

  app.post('/api/v1/library/seed-demo', async (c) => {
    try {
      const seeded = await seedSampleLibrary(ctx.db, ctx.media, false);
      if (seeded) {
        ctx.events.emitLibraryChanged('seed-demo');
      }
      return c.json({ seeded });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.get('/api/v1/library/quick-jump', (c) => {
    const q = c.req.query('q') ?? '';
    const limitRaw = Number.parseInt(c.req.query('limit') ?? '24', 10);
    const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(100, limitRaw)) : 24;
    return c.json({ matches: ctx.db.quickJump(q, limit) });
  });

  // MARK: - Assets Query, CRUD, Ingest, Upload, Refresh & Extraction

  app.post('/api/v1/assets/query', async (c) => {
    try {
      const body = (await c.req.json().catch(() => ({}))) as AssetsQueryRequest;
      const limit = body.limit;
      const offset = body.offset;

      if (body.smartFolderID) {
        const allMatched = ctx.db.fetchAssetsForSmartFolder(body.smartFolderID, body.criteria);
        const start = offset && offset > 0 ? Math.trunc(offset) : 0;
        const page =
          limit !== undefined && limit !== null
            ? allMatched.slice(start, start + Math.max(0, Math.trunc(limit)))
            : allMatched.slice(start);
        return c.json({ assets: page, total: allMatched.length });
      }

      const assets = ctx.db.fetchAssets(body.criteria, limit, offset);
      const total = ctx.db.countAssets(body.criteria);
      return c.json({ assets, total });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.get('/api/v1/assets/recent-activity', (c) => {
    const limitRaw = Number.parseInt(c.req.query('limit') ?? '24', 10);
    const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(200, limitRaw)) : 24;
    const assets = ctx.db.recentActivityAssets(limit);
    return c.json({ assets, total: assets.length });
  });

  app.get('/api/v1/assets/:id', (c) => {
    const asset = ctx.db.getAsset(c.req.param('id'));
    if (!asset) {
      return c.json({ error: '素材不存在。', code: 'NOT_FOUND' }, 404);
    }
    return c.json({ asset });
  });

  app.post('/api/v1/assets/ingest', async (c) => {
    try {
      const body = (await c.req.json()) as Partial<IngestRequest>;
      const inputs = Array.isArray(body.inputs) ? body.inputs : [];
      if (inputs.length === 0) {
        return c.json({ error: '请提供至少一个待导入项。', code: 'INVALID_INPUT' }, 400);
      }
      const targetFolderID = body.targetFolderID ? toSwiftUUID(body.targetFolderID) : null;
      const created: AssetRecord[] = [];

      for (const input of inputs) {
        const res = await ctx.media.ingest(input, targetFolderID);
        const saved = ctx.db.saveAssetLocally(res.asset);
        if (res.vector) {
          ctx.db.saveVector(saved.id, res.vector);
        }
        ctx.db.touchOriginal(saved.id);
        ctx.db.markProjection('thumbnails', saved.id);
        created.push(saved);
      }

      if (body.targetBoardID) {
        appendAssetsToBoard(ctx, body.targetBoardID, created);
      }
      ctx.events.emitLibraryChanged(
        'ingest',
        created.map((a) => a.id),
      );
      return c.json({ assets: created }, 201);
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/assets/upload', async (c) => {
    try {
      const form = await c.req.formData();
      const targetFolderRaw = form.get('targetFolderID');
      const targetBoardRaw = form.get('targetBoardID');
      const targetFolderID =
        typeof targetFolderRaw === 'string' && targetFolderRaw.trim()
          ? toSwiftUUID(targetFolderRaw.trim())
          : null;
      const targetBoardID =
        typeof targetBoardRaw === 'string' && targetBoardRaw.trim()
          ? toSwiftUUID(targetBoardRaw.trim())
          : null;

      const fileEntries = [...form.getAll('files'), ...form.getAll('file')].filter(
        (v): v is File => typeof v !== 'string' && typeof v.arrayBuffer === 'function',
      );
      if (fileEntries.length === 0) {
        return c.json({ error: '未检测到上传文件。', code: 'NO_FILES' }, 400);
      }

      const created: AssetRecord[] = [];
      for (const file of fileEntries) {
        const buf = Buffer.from(await file.arrayBuffer());
        const res = await ctx.media.ingestUploadedFile(
          buf,
          file.name || 'upload',
          file.type || null,
          targetFolderID,
        );
        const saved = ctx.db.saveAssetLocally(res.asset);
        if (res.vector) {
          ctx.db.saveVector(saved.id, res.vector);
        }
        ctx.db.touchOriginal(saved.id);
        ctx.db.markProjection('thumbnails', saved.id);
        created.push(saved);
      }

      if (targetBoardID) {
        appendAssetsToBoard(ctx, targetBoardID, created);
      }
      ctx.events.emitLibraryChanged(
        'upload',
        created.map((a) => a.id),
      );
      return c.json({ assets: created }, 201);
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.patch('/api/v1/assets/batch', async (c) => {
    try {
      const patch = (await c.req.json()) as AssetBatchPatch;
      const assets = ctx.db.applyBatchPatch(patch);
      ctx.events.emitLibraryChanged(
        'batch-patch',
        assets.map((a) => a.id),
      );
      return c.json({ assets });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/assets/permanent-delete', async (c) => {
    try {
      const body = (await c.req.json()) as { ids?: UUID[] };
      const ids = Array.isArray(body.ids) ? body.ids : [];
      if (ids.length > 0) {
        ctx.db.permanentDeleteAssets(ids);
        await ctx.media.removeFilesByIDs(ids);
        ctx.events.emitLibraryChanged('permanent-delete', ids);
      }
      return c.json({ ok: true as const });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/assets/empty-trash', async (c) => {
    try {
      const trashed = ctx.db.fetchAssets({ onlyTrashed: true });
      const ids = trashed.map((a) => a.id);
      if (ids.length > 0) {
        ctx.db.permanentDeleteAssets(ids);
        await ctx.media.removeFilesByIDs(ids);
        ctx.events.emitLibraryChanged('empty-trash', ids);
      }
      return c.json({ ok: true as const });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/assets/restore-all-trash', (c) => {
    const trashed = ctx.db.fetchAssets({ onlyTrashed: true });
    if (trashed.length > 0) {
      ctx.db.applyBatchPatch({
        assetIDs: trashed.map((a) => a.id),
        addTags: [],
        removeTags: [],
        acceptSuggestedTags: false,
        dismissSuggestedTags: [],
        folderAssignment: { type: 'unchanged' },
        isTrashed: false,
      });
      ctx.events.emitLibraryChanged(
        'restore-all-trash',
        trashed.map((a) => a.id),
      );
    }
    return c.json({ ok: true as const });
  });

  app.post('/api/v1/assets/:id/opened', (c) => {
    ctx.db.markAssetOpened(c.req.param('id'));
    return c.json({ ok: true as const });
  });

  app.get('/api/v1/assets/:id/similar', (c) => {
    const limitRaw = Number.parseInt(c.req.query('limit') ?? '12', 10);
    const limit = Number.isFinite(limitRaw) ? Math.max(1, Math.min(60, limitRaw)) : 12;
    return c.json({ items: ctx.db.similarAssets(c.req.param('id'), limit) });
  });

  app.get('/api/v1/assets/:id/suggest-folder', (c) => {
    return c.json({ suggestion: ctx.db.suggestFolder(c.req.param('id')) });
  });

  app.post('/api/v1/assets/:id/refresh-rich', async (c) => {
    try {
      const existing = ctx.db.getAsset(c.req.param('id'));
      if (!existing) {
        return c.json({ error: '素材不存在。', code: 'NOT_FOUND' }, 404);
      }
      const refreshed = await ctx.media.refreshRichAsset(existing);
      const saved = ctx.db.saveAssetLocally(refreshed.asset);
      if (refreshed.vector) {
        ctx.db.saveVector(saved.id, refreshed.vector);
      }
      ctx.db.markProjection('thumbnails', saved.id);
      ctx.events.emitLibraryChanged('refresh-rich', [saved.id]);
      return c.json({ asset: saved });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/assets/:id/extract-social-media', async (c) => {
    try {
      const postAsset = ctx.db.getAsset(c.req.param('id'));
      if (!postAsset) {
        return c.json({ error: '素材不存在。', code: 'NOT_FOUND' }, 404);
      }
      const body = (await c.req.json().catch(() => ({}))) as ExtractSocialMediaRequest;
      const extracted = await ctx.media.extractSocialMedia(postAsset, body.attachmentIndex ?? null);
      const savedAssets: AssetRecord[] = [];
      for (const item of extracted) {
        const saved = ctx.db.saveAssetLocally(item.asset);
        if (item.vector) ctx.db.saveVector(saved.id, item.vector);
        ctx.db.touchOriginal(saved.id);
        ctx.db.markProjection('thumbnails', saved.id);
        savedAssets.push(saved);
      }
      ctx.events.emitLibraryChanged(
        'extract-social-media',
        savedAssets.map((a) => a.id),
      );
      return c.json({ assets: savedAssets }, 201);
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  // MARK: - Authenticated Media Serving (Thumbnails + Range-capable Originals)

  app.get('/api/v1/media/:id/thumbnail/:tier', async (c) => {
    const id = c.req.param('id');
    const rawTier = c.req.param('tier');
    const tier: ThumbnailTier = rawTier === 'preview1400' ? 'preview1400' : 'grid520';
    const thumbPath = ctx.media.getThumbnailPath(id, tier);
    if (!thumbPath) {
      return c.json({ error: '缩略图不存在。', code: 'NOT_FOUND' }, 404);
    }
    const stat = await fsp.stat(thumbPath).catch(() => null);
    if (!stat) {
      return c.json({ error: '缩略图不存在。', code: 'NOT_FOUND' }, 404);
    }
    const etag = `"${stat.size}-${Math.trunc(stat.mtimeMs)}"`;
    if (c.req.header('if-none-match') === etag) {
      return new Response(null, { status: 304, headers: { ETag: etag } });
    }
    const buf = await fsp.readFile(thumbPath);
    return new Response(new Uint8Array(buf), {
      status: 200,
      headers: {
        'Content-Type': 'image/jpeg',
        'Content-Length': String(buf.length),
        'Cache-Control': 'private, max-age=3600',
        ETag: etag,
      },
    });
  });

  app.get('/api/v1/media/:id/original', async (c) => {
    try {
      const id = c.req.param('id');
      const asset = ctx.db.getAsset(id);
      if (!asset) {
        return c.json({ error: '素材不存在。', code: 'NOT_FOUND' }, 404);
      }
      const cachedOnlyQuery = (c.req.query('cachedOnly') ?? '').trim().toLowerCase();
      const cachedOnly = cachedOnlyQuery === '1' || cachedOnlyQuery === 'true';
      let filePath = ctx.media.cachedOriginalPath(asset);
      if (!filePath && !cachedOnly) {
        filePath = await ctx.sync.downloadOriginal(asset);
      }
      if (!filePath || !fs.existsSync(filePath)) {
        return c.json(
          {
            error: '原始文件暂未缓存到本地。',
            code: cachedOnly ? 'NOT_CACHED' : 'NOT_FOUND',
          },
          404,
        );
      }

      if (!cachedOnly) {
        ctx.db.touchOriginal(asset.id);
      }
      const stat = await fsp.stat(filePath);
      const totalSize = stat.size;
      const mimeType = asset.mimeType || 'application/octet-stream';
      const download = c.req.query('download') === '1';

      const headers: Record<string, string> = {
        'Content-Type': mimeType,
        'Accept-Ranges': 'bytes',
        'Cache-Control': 'private, max-age=600',
      };
      if (mimeType === 'application/pdf') {
        // Allow same-origin Quick Look PDF iframe rendering
        headers['X-Frame-Options'] = 'SAMEORIGIN';
      }
      if (download) {
        headers['Content-Disposition'] = `attachment; filename*=UTF-8''${encodeURIComponent(asset.fileName)}`;
      } else {
        headers['Content-Disposition'] = `inline; filename*=UTF-8''${encodeURIComponent(asset.fileName)}`;
      }

      const rangeHeader = c.req.header('range');
      if (rangeHeader && rangeHeader.startsWith('bytes=')) {
        const match = /^bytes=(\d*)-(\d*)$/.exec(rangeHeader.trim());
        if (!match) {
          return new Response(null, {
            status: 416,
            headers: { 'Content-Range': `bytes */${totalSize}` },
          });
        }
        let start = match[1] ? Number.parseInt(match[1], 10) : 0;
        let end = match[2] ? Number.parseInt(match[2], 10) : totalSize - 1;
        if (!match[1] && match[2]) {
          // Suffix range: bytes=-N
          const suffixLen = Number.parseInt(match[2], 10);
          start = Math.max(0, totalSize - suffixLen);
          end = totalSize - 1;
        }
        if (start >= totalSize || start > end || start < 0) {
          return new Response(null, {
            status: 416,
            headers: { 'Content-Range': `bytes */${totalSize}` },
          });
        }
        end = Math.min(end, totalSize - 1);
        const chunkLen = end - start + 1;
        const fh = await fsp.open(filePath, 'r');
        try {
          const chunk = Buffer.alloc(chunkLen);
          const { bytesRead } = await fh.read(chunk, 0, chunkLen, start);
          return new Response(new Uint8Array(chunk.subarray(0, bytesRead)), {
            status: 206,
            headers: {
              ...headers,
              'Content-Range': `bytes ${start}-${start + bytesRead - 1}/${totalSize}`,
              'Content-Length': String(bytesRead),
            },
          });
        } finally {
          await fh.close();
        }
      }

      const fullBuf = await fsp.readFile(filePath);
      return new Response(new Uint8Array(fullBuf), {
        status: 200,
        headers: {
          ...headers,
          'Content-Length': String(fullBuf.length),
        },
      });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  // MARK: - Folders, Smart Folders & Tags

  app.get('/api/v1/folders', (c) => {
    return c.json({ folders: ctx.db.fetchFolders() });
  });

  app.post('/api/v1/folders', async (c) => {
    try {
      const body = (await c.req.json()) as Partial<CreateFolderRequest>;
      const folder = ctx.db.createFolder(String(body.name ?? ''), body.parentID ?? null);
      ctx.events.emitLibraryChanged('folder-create', undefined, [folder.id]);
      return c.json({ folder }, 201);
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.patch('/api/v1/folders/:id', async (c) => {
    try {
      const body = (await c.req.json()) as Partial<RenameFolderRequest>;
      const folder = ctx.db.renameFolder(c.req.param('id'), String(body.name ?? ''));
      ctx.events.emitLibraryChanged('folder-rename', undefined, [folder.id]);
      return c.json({ folder });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/folders/:id/move', async (c) => {
    try {
      const body = (await c.req.json()) as MoveFolderRequest;
      const folders = ctx.db.moveFolder(
        c.req.param('id'),
        body.newParentID ?? null,
        body.insertAtIndex ?? null,
      );
      ctx.events.emitLibraryChanged('folder-move', undefined, [toSwiftUUID(c.req.param('id'))]);
      return c.json({ folders });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.patch('/api/v1/folders/:id/appearance', async (c) => {
    try {
      const body = (await c.req.json()) as UpdateFolderAppearanceRequest;
      const folder = ctx.db.updateFolderAppearance(c.req.param('id'), body);
      ctx.events.emitLibraryChanged('folder-appearance', undefined, [folder.id]);
      return c.json({ folder });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.delete('/api/v1/folders/:id', (c) => {
    try {
      const trashContents = c.req.query('trashContents') === 'true';
      const id = toSwiftUUID(c.req.param('id'));
      ctx.db.deleteFolder(id, trashContents);
      ctx.events.emitLibraryChanged('folder-delete', undefined, [id]);
      return c.json({ ok: true as const });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/folders/:id/pin-offline', async (c) => {
    try {
      const body = (await c.req.json()) as { pinned?: boolean };
      const pinned = Boolean(body.pinned);
      const id = toSwiftUUID(c.req.param('id'));
      const assets = ctx.db.fetchAssets({
        folderID: id,
        includeSubfolders: true,
        includeTrashed: false,
      });
      if (assets.length > 0) {
        ctx.db.applyBatchPatch({
          assetIDs: assets.map((a) => a.id),
          addTags: [],
          removeTags: [],
          acceptSuggestedTags: false,
          dismissSuggestedTags: [],
          folderAssignment: { type: 'unchanged' },
          pinnedOffline: pinned,
        });
        ctx.events.emitLibraryChanged(
          'folder-pin-offline',
          assets.map((a) => a.id),
          [id],
        );
      }
      return c.json({ ok: true as const });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.get('/api/v1/smart-folders', (c) => {
    return c.json({ smartFolders: ctx.db.fetchSmartFolders() });
  });

  app.put('/api/v1/smart-folders', async (c) => {
    try {
      const body = (await c.req.json()) as Partial<SaveSmartFolderRequest>;
      const now = new Date().toISOString();
      const existing = body.id
        ? ctx.db.fetchSmartFolders().find((s) => toSwiftUUID(s.id) === toSwiftUUID(body.id!))
        : undefined;
      const record: SmartFolderRecord = {
        id: body.id ? toSwiftUUID(body.id) : toSwiftUUID(crypto.randomUUID()),
        name: String(body.name ?? '').trim() || '智能文件夹',
        colorHex: body.colorHex ?? body.rule?.colorHexes?.[0] ?? null,
        rule: createDefaultSmartFolderRule(body.rule ?? {}),
        sortOrder:
          typeof body.sortOrder === 'number'
            ? body.sortOrder
            : (existing?.sortOrder ?? ctx.db.fetchSmartFolders().length),
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      };
      ctx.db.saveSmartFolder(record);
      ctx.events.emitLibraryChanged('smart-folder-save');
      return c.json({ smartFolders: ctx.db.fetchSmartFolders() });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.delete('/api/v1/smart-folders/:id', (c) => {
    ctx.db.deleteSmartFolder(c.req.param('id'));
    ctx.events.emitLibraryChanged('smart-folder-delete');
    return c.json({ smartFolders: ctx.db.fetchSmartFolders() });
  });

  app.get('/api/v1/tags', (c) => {
    return c.json({ tags: ctx.db.fetchTagCounts() });
  });

  // MARK: - Moodboards CRUD

  app.get('/api/v1/boards', (c) => {
    return c.json({ boards: ctx.db.fetchBoardSummaries() });
  });

  app.post('/api/v1/boards', async (c) => {
    try {
      const body = (await c.req.json()) as Partial<CreateBoardRequest>;
      const now = new Date().toISOString();
      const seedIDs = Array.isArray(body.seedAssetIDs) ? body.seedAssetIDs : [];
      const nodes: BoardNode[] = [];
      const palette: LabColor[] = [];
      const assetsByID: Record<string, AssetRecord> = {};

      for (let i = 0; i < seedIDs.length; i++) {
        const asset = ctx.db.getAsset(seedIDs[i]);
        if (!asset) continue;
        assetsByID[asset.id] = asset;
        const ratio =
          asset.pixelWidth > 0 && asset.pixelHeight > 0
            ? Math.max(0.5, Math.min(2.2, asset.pixelWidth / asset.pixelHeight))
            : 1.25;
        const w = 280;
        const h = Math.round(w / ratio);
        nodes.push({
          id: toSwiftUUID(crypto.randomUUID()),
          kind: {
            type: 'assetRef',
            assetID: asset.id,
            crop: null,
            weight: i === 0 ? 2 : 1,
            autoplayLoop: true,
          },
          frame: {
            x: 40 + (i % 4) * 304,
            y: 40 + Math.floor(i / 4) * 320,
            width: w,
            height: h,
          },
          zIndex: i + 1,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: i,
          updatedAt: now,
        });
        if (palette.length < 7 && asset.dominantColors[0]) {
          palette.push(asset.dominantColors[0]);
        }
      }

      const rawDoc = createDefaultMoodboardDocument({
        id: toSwiftUUID(crypto.randomUUID()),
        title: String(body.title ?? '').trim() || '未命名情绪板',
        subtitle: String(body.subtitle ?? ''),
        mode:
          nodes.length > 0
            ? {
                type: 'autoEditorial',
                config: createDefaultAutoLayoutConfig({
                  columns: Math.min(4, Math.max(2, nodes.length)),
                  spacing: 16,
                  style: 'balanced',
                  showPaletteStrip: true,
                }),
              }
            : { type: 'freeform' },
        nodes,
        extractedPalette: palette,
        createdAt: now,
        updatedAt: now,
      });
      const doc = nodes.length > 0 ? freezeIntoFreeform(rawDoc, 1080, assetsByID) : rawDoc;
      const saved = ctx.db.saveBoardLocally(doc);
      ctx.events.emitBoardUpdated(saved.id);
      return c.json({ board: saved }, 201);
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.get('/api/v1/boards/:id', (c) => {
    const board = ctx.db.getBoard(c.req.param('id'));
    if (!board) {
      return c.json({ error: '情绪板不存在。', code: 'NOT_FOUND' }, 404);
    }
    return c.json({ board });
  });

  app.put('/api/v1/boards/:id', async (c) => {
    try {
      const id = toSwiftUUID(c.req.param('id'));
      const body = (await c.req.json()) as Partial<SaveBoardRequest>;
      if (!body.document) {
        return c.json({ error: '缺少 document 参数。', code: 'INVALID_INPUT' }, 400);
      }
      const saved = ctx.db.saveBoardLocally({
        ...body.document,
        id,
        updatedAt: new Date().toISOString(),
      });
      ctx.events.emitBoardUpdated(saved.id);
      return c.json({ board: saved });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.delete('/api/v1/boards/:id', (c) => {
    const id = toSwiftUUID(c.req.param('id'));
    ctx.db.deleteBoardLocally(id);
    ctx.events.emitBoardUpdated(id, true);
    return c.json({ ok: true as const });
  });

  // MARK: - Sync & Cache Routes

  app.get('/api/v1/sync/config', (c) => {
    return c.json(buildSyncConfigResponse(ctx));
  });

  app.put('/api/v1/sync/config', async (c) => {
    try {
      const body = (await c.req.json()) as SaveSyncConfigRequest;
      await ctx.sync.updateConfig(body.config, body.webDAVPassword ?? null);
      return c.json(buildSyncConfigResponse(ctx));
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.put('/api/v1/sync/google/oauth-config', async (c) => {
    try {
      const body = (await c.req.json()) as SaveGoogleOAuthConfigRequest;
      const engine = ctx.sync as DriveSyncEngine;
      if (typeof engine.googleOAuth?.saveClientCredentials === 'function') {
        engine.googleOAuth.saveClientCredentials(
          String(body.clientID ?? ''),
          String(body.clientSecret ?? ''),
        );
      } else {
        ctx.secretVault.set(SECRET_KEYS.GOOGLE_OAUTH_CLIENT_ID, String(body.clientID ?? '').trim());
        ctx.secretVault.set(
          SECRET_KEYS.GOOGLE_OAUTH_CLIENT_SECRET,
          String(body.clientSecret ?? '').trim(),
        );
      }
      return c.json(buildSyncConfigResponse(ctx));
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/sync/google/oauth/start', (c) => {
    try {
      const origin = new URL(c.req.url).origin;
      const redirectUri = `${origin}/api/v1/sync/google/callback`;
      const result = ctx.sync.startGoogleOAuth(redirectUri);
      return c.json(result);
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.get('/api/v1/sync/google/callback', async (c) => {
    try {
      const code = c.req.query('code') ?? '';
      const state = c.req.query('state') ?? '';
      if (!code || !state) {
        return c.html('<html><body><p>授权已取消或参数不完整。</p></body></html>', 400);
      }
      const origin = new URL(c.req.url).origin;
      const redirectUri = `${origin}/api/v1/sync/google/callback`;
      const account = await ctx.sync.completeGoogleOAuth(code, state, redirectUri);
      return c.html(
        `<!doctype html><html><body style="font-family:-apple-system,sans-serif;padding:32px;background:#F6F6F5;color:#1C1D21">
          <h2>Google Drive 已连接</h2>
          <p>账号：${account.email.replace(/[<>&]/g, '')}</p>
          <script>if(window.opener){window.opener.postMessage({type:'charkle-google-oauth-done'},'*');window.close();}else{window.location.href='/';}</script>
        </body></html>`,
      );
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'OAuth 授权失败';
      return c.html(
        `<!doctype html><html><body style="font-family:-apple-system,sans-serif;padding:32px"><h2>授权失败</h2><p>${msg.replace(/[<>&]/g, '')}</p></body></html>`,
        400,
      );
    }
  });

  app.post('/api/v1/sync/google/sign-out', async (c) => {
    try {
      await ctx.sync.signOutGoogle();
      return c.json(buildSyncConfigResponse(ctx));
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.get('/api/v1/sync/google/shared-folders', async (c) => {
    try {
      const folders = await ctx.sync.listSharedGoogleDriveFolders();
      return c.json({ folders });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/sync/webdav/test', async (c) => {
    try {
      const body = (await c.req.json()) as TestWebDAVRequest;
      const account = await ctx.sync.testWebDAV(body.config, body.password ?? null);
      return c.json({ account });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/sync/now', async (c) => {
    try {
      const result = await ctx.sync.syncNow();
      return c.json(result);
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/sync/migrate', async (c) => {
    try {
      const body = (await c.req.json()) as MigrateStorageRequest;
      const report = await ctx.sync.migrateStorage(
        body.targetConfig,
        body.webDAVPassword ?? null,
      );
      ctx.events.emitLibraryChanged('storage-migration');
      return c.json({ report });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.get('/api/v1/cache/stats', async (c) => {
    const stats = await ctx.media.getCacheStats(ctx.db);
    return c.json({ stats });
  });

  app.put('/api/v1/cache/budget', async (c) => {
    try {
      const body = (await c.req.json()) as Partial<UpdateCacheBudgetRequest>;
      const bytes = Number(body.budgetBytes);
      if (!Number.isFinite(bytes) || bytes <= 0) {
        return c.json({ error: '无效的缓存上限大小。', code: 'INVALID_INPUT' }, 400);
      }
      const saved = ctx.configStore.setCacheBudgetBytes(bytes);
      ctx.media.setCacheBudgetBytes(saved);
      const stats = await ctx.media.getCacheStats(ctx.db);
      return c.json({ stats });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  app.post('/api/v1/cache/evict', async (c) => {
    try {
      const stats = await ctx.media.evictCacheNow(ctx.db);
      ctx.events.emitLibraryChanged('cache-evict');
      return c.json({ stats });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  // MARK: - Browser Clipper Extension ZIP Download

  app.get('/api/v1/extension/download', async (c) => {
    try {
      const extDir = resolveExtensionDir();
      if (!extDir) {
        return c.json({ error: '浏览器扩展包暂不可用。', code: 'NOT_FOUND' }, 404);
      }
      const files = await collectExtensionFiles(extDir);
      if (files.length === 0) {
        return c.json({ error: '浏览器扩展目录为空。', code: 'NOT_FOUND' }, 404);
      }

      const zip = new JSZip();
      for (const file of files) {
        const data = await fsp.readFile(file.absPath);
        zip.file(file.relPath, data);
      }

      const zipBuf = await zip.generateAsync({
        type: 'nodebuffer',
        compression: 'DEFLATE',
        compressionOptions: { level: 6 },
      });

      return new Response(new Uint8Array(zipBuf), {
        status: 200,
        headers: {
          'Content-Type': 'application/zip',
          'Content-Disposition': 'attachment; filename="charkle-web-clipper-extension.zip"',
          'Content-Length': String(zipBuf.length),
          'Cache-Control': 'private, no-cache',
        },
      });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });

  // MARK: - Figma / FigJam Bridge Plugin ZIP Download

  app.get('/api/v1/figma-plugin/download', async (c) => {
    try {
      const pluginDir = resolveFigmaPluginDir();
      if (!pluginDir) {
        return c.json({ error: 'Figma 桥接插件包暂不可用。', code: 'NOT_FOUND' }, 404);
      }
      const files = await collectFigmaPluginFiles(pluginDir);
      if (files.length === 0) {
        return c.json({ error: 'Figma 桥接插件目录为空。', code: 'NOT_FOUND' }, 404);
      }

      const zip = new JSZip();
      for (const file of files) {
        const data = await fsp.readFile(file.absPath);
        zip.file(file.relPath, data);
      }

      const zipBuf = await zip.generateAsync({
        type: 'nodebuffer',
        compression: 'DEFLATE',
        compressionOptions: { level: 6 },
      });

      return new Response(new Uint8Array(zipBuf), {
        status: 200,
        headers: {
          'Content-Type': 'application/zip',
          'Content-Disposition': 'attachment; filename="charkle-figma-bridge-plugin.zip"',
          'Content-Length': String(zipBuf.length),
          'Cache-Control': 'private, no-cache',
        },
      });
    } catch (err) {
      return handleRouteError(c, err);
    }
  });
}

const EXCLUDED_EXTENSION_DIRS = new Set(['tests', 'test', '__tests__', 'node_modules']);
const EXCLUDED_EXTENSION_FILES = new Set([
  '.DS_Store',
  'Thumbs.db',
  'package.json',
  'package-lock.json',
  'tsconfig.json',
]);

function isExcludedExtensionFileName(name: string): boolean {
  if (name.startsWith('.')) return true;
  if (EXCLUDED_EXTENSION_FILES.has(name)) return true;
  if (/^vitest\.config\./i.test(name)) return true;
  if (/\.(?:test|spec)\.[^.]+$/i.test(name)) return true;
  if (/\.map$/i.test(name)) return true;
  return false;
}

export function resolveExtensionDir(): string | null {
  const envDir = process.env.CHARKLE_EXTENSION_DIR?.trim();
  if (envDir) {
    const resolved = path.resolve(envDir);
    return fs.existsSync(path.join(resolved, 'manifest.json')) ? resolved : null;
  }

  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    path.resolve(here, '../../../extension'),
    path.resolve(process.cwd(), 'packages/extension'),
    path.resolve(process.cwd(), '../extension'),
  ];
  for (const dir of candidates) {
    if (fs.existsSync(path.join(dir, 'manifest.json'))) {
      return dir;
    }
  }
  return null;
}

async function collectExtensionFiles(
  rootDir: string,
  subDir = '',
): Promise<Array<{ absPath: string; relPath: string }>> {
  const currentDir = subDir ? path.join(rootDir, subDir) : rootDir;
  const entries = await fsp.readdir(currentDir, { withFileTypes: true });
  entries.sort((a, b) => a.name.localeCompare(b.name));

  const results: Array<{ absPath: string; relPath: string }> = [];
  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (entry.name.startsWith('.') || EXCLUDED_EXTENSION_DIRS.has(entry.name)) {
        continue;
      }
      const nextSub = subDir ? `${subDir}/${entry.name}` : entry.name;
      const nested = await collectExtensionFiles(rootDir, nextSub);
      results.push(...nested);
    } else if (entry.isFile()) {
      if (isExcludedExtensionFileName(entry.name)) {
        continue;
      }
      const absPath = path.join(currentDir, entry.name);
      const relPath = subDir ? `${subDir}/${entry.name}` : entry.name;
      results.push({ absPath, relPath });
    }
  }
  return results;
}

const EXCLUDED_FIGMA_FILES = new Set(['.DS_Store', 'Thumbs.db', 'ui-template.html']);

export function resolveFigmaPluginDir(): string | null {
  const envDir = process.env.CHARKLE_FIGMA_PLUGIN_DIR?.trim();
  if (envDir) {
    const resolved = path.resolve(envDir);
    return fs.existsSync(path.join(resolved, 'manifest.json')) ? resolved : null;
  }

  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    path.resolve(here, '../../../../figma-plugin'),
    path.resolve(here, '../../../figma-plugin'),
    path.resolve(process.cwd(), 'figma-plugin'),
    path.resolve(process.cwd(), '../../figma-plugin'),
  ];
  for (const dir of candidates) {
    if (fs.existsSync(path.join(dir, 'manifest.json'))) {
      return dir;
    }
  }
  return null;
}

async function collectFigmaPluginFiles(
  rootDir: string,
  subDir = '',
): Promise<Array<{ absPath: string; relPath: string }>> {
  const currentDir = subDir ? path.join(rootDir, subDir) : rootDir;
  const entries = await fsp.readdir(currentDir, { withFileTypes: true });
  entries.sort((a, b) => a.name.localeCompare(b.name));

  const results: Array<{ absPath: string; relPath: string }> = [];
  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (entry.name.startsWith('.') || EXCLUDED_EXTENSION_DIRS.has(entry.name)) {
        continue;
      }
      const nextSub = subDir ? `${subDir}/${entry.name}` : entry.name;
      const nested = await collectFigmaPluginFiles(rootDir, nextSub);
      results.push(...nested);
    } else if (entry.isFile()) {
      if (entry.name.startsWith('.') || EXCLUDED_FIGMA_FILES.has(entry.name)) {
        continue;
      }
      const absPath = path.join(currentDir, entry.name);
      const relPath = subDir ? `${subDir}/${entry.name}` : entry.name;
      results.push({ absPath, relPath });
    }
  }
  return results;
}
