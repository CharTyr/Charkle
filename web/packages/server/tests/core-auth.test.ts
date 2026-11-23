import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterEach, describe, expect, it } from 'vitest';
import { createApp, createServerContext } from '../src/app.js';
import { LoginRateLimiter } from '../src/auth/rate-limiter.js';

const tempDirs: string[] = [];

function createTestServer() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-auth-test-'));
  tempDirs.push(dir);
  const ctx = createServerContext({ dataDir: dir, vaultSecret: 'auth-test-vault-key' });
  const rateLimiter = new LoginRateLimiter(10, 15 * 60 * 1000);
  const app = createApp(ctx, { rateLimiter, staticClientDir: null });
  return { dir, ctx, app, rateLimiter };
}

function extractSessionCookie(res: Response): string {
  const setCookie = res.headers.get('set-cookie') ?? '';
  const match = /charkle_session=([^;]+)/.exec(setCookie);
  return match ? `charkle_session=${match[1]}` : '';
}

afterEach(() => {
  delete process.env.CHARKLE_ADMIN_USERNAME;
  delete process.env.CHARKLE_ADMIN_PASSWORD;
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe('Auth, Security Middleware, Sessions, PATs, Rate Limiter & Core REST API', () => {
  it('enforces setup validation, strict 401 on all protected endpoints, security headers, and session lifecycle', async () => {
    const { ctx, app } = createTestServer();
    try {
      // 1. Public health + security headers
      const healthRes = await app.request('/api/v1/health');
      expect(healthRes.status).toBe(200);
      expect(healthRes.headers.get('x-content-type-options')).toBe('nosniff');
      expect(healthRes.headers.get('x-frame-options')).toBe('DENY');
      expect(healthRes.headers.get('referrer-policy')).toBe('same-origin');

      // 2. Uninitialized auth status
      const status0 = await (await app.request('/api/v1/auth/status')).json();
      expect(status0.initialized).toBe(false);
      expect(status0.authenticated).toBe(false);

      // 3. Strict 401 on ALL protected routes (including media, SSE, exports, MCP)
      const protectedPaths: Array<[string, string]> = [
        ['GET', '/api/v1/library/bootstrap'],
        ['POST', '/api/v1/assets/query'],
        ['GET', '/api/v1/media/00000000-0000-0000-0000-000000000001/thumbnail/grid520'],
        ['GET', '/api/v1/media/00000000-0000-0000-0000-000000000001/original'],
        ['GET', '/api/v1/events'],
        ['GET', '/api/v1/boards'],
        ['POST', '/api/v1/boards/00000000-0000-0000-0000-000000000001/export/figma'],
        ['POST', '/api/v1/mcp'],
      ];
      for (const [method, url] of protectedPaths) {
        const res = await app.request(url, { method });
        expect(res.status, `${method} ${url} must return 401`).toBe(401);
      }

      // 4. Setup validation failures
      const badUser = await app.request('/api/v1/auth/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: 'a', password: 'strongpassword123' }),
      });
      expect(badUser.status).toBe(400);

      const badPass = await app.request('/api/v1/auth/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: 'admin', password: 'short' }),
      });
      expect(badPass.status).toBe(400);

      // 5. Successful first-launch setup issues HttpOnly SameSite=Lax cookie (+ Secure behind HTTPS proxy)
      const setupRes = await app.request('/api/v1/auth/setup', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Forwarded-Proto': 'https',
          'User-Agent': 'CharkleTestBrowser/1.0',
        },
        body: JSON.stringify({
          username: 'char',
          password: 'super-secret-password',
          displayName: 'Char',
        }),
      });
      expect(setupRes.status).toBe(201);
      const rawSetCookie = setupRes.headers.get('set-cookie') ?? '';
      expect(rawSetCookie).toContain('HttpOnly');
      expect(rawSetCookie).toContain('SameSite=Lax');
      expect(rawSetCookie).toContain('Path=/');
      expect(rawSetCookie).toContain('Secure');
      const cookie1 = extractSessionCookie(setupRes);
      expect(cookie1).toContain('charkle_session=');

      // Duplicate setup must be rejected with 409
      const dupSetup = await app.request('/api/v1/auth/setup', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: 'other', password: 'another-password' }),
      });
      expect(dupSetup.status).toBe(409);

      // 6. Authenticated bootstrap works with session cookie
      const bootRes = await app.request('/api/v1/library/bootstrap', {
        headers: { Cookie: cookie1 },
      });
      expect(bootRes.status).toBe(200);

      // 7. Second device login + list sessions + revoke other sessions + change password
      const login2 = await app.request('/api/v1/auth/login', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'SecondDevice/2.0',
        },
        body: JSON.stringify({
          username: 'char',
          password: 'super-secret-password',
          rememberMe: false,
        }),
      });
      expect(login2.status).toBe(200);
      const cookie2 = extractSessionCookie(login2);

      const sessionsRes = await (
        await app.request('/api/v1/auth/sessions', { headers: { Cookie: cookie1 } })
      ).json();
      expect(sessionsRes.sessions).toHaveLength(2);
      expect(sessionsRes.sessions.some((s: { isCurrent: boolean }) => s.isCurrent)).toBe(true);

      // Change password from device 1 -> must revoke device 2 session!
      const chgRes = await app.request('/api/v1/auth/change-password', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Cookie: cookie1 },
        body: JSON.stringify({
          currentPassword: 'super-secret-password',
          newPassword: 'brand-new-password-99',
        }),
      });
      expect(chgRes.status).toBe(200);

      // Device 2 session is now revoked -> 401
      const dev2After = await app.request('/api/v1/library/bootstrap', {
        headers: { Cookie: cookie2 },
      });
      expect(dev2After.status).toBe(401);

      // Device 1 still authenticated -> logout revokes it
      const logoutRes = await app.request('/api/v1/auth/logout', {
        method: 'POST',
        headers: { Cookie: cookie1 },
      });
      expect(logoutRes.status).toBe(200);
      const dev1After = await app.request('/api/v1/library/bootstrap', {
        headers: { Cookie: cookie1 },
      });
      expect(dev1After.status).toBe(401);
    } finally {
      ctx.db.close();
    }
  });

  it('enforces sliding-window login rate limiting (10 failures -> HTTP 429 with Retry-After)', async () => {
    const { ctx, app } = createTestServer();
    try {
      await ctx.auth.setupAdmin('admin', 'correct-horse-battery');

      for (let i = 1; i <= 9; i++) {
        const res = await app.request('/api/v1/auth/login', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-Forwarded-For': '203.0.113.5' },
          body: JSON.stringify({ username: 'admin', password: `wrong-${i}` }),
        });
        expect(res.status).toBe(401);
      }

      // 10th failure triggers 429 with Retry-After
      const tenth = await app.request('/api/v1/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Forwarded-For': '203.0.113.5' },
        body: JSON.stringify({ username: 'admin', password: 'wrong-10' }),
      });
      expect(tenth.status).toBe(429);
      const retryAfter = Number(tenth.headers.get('retry-after'));
      expect(retryAfter).toBeGreaterThan(0);

      // Even with correct password from same IP+username, still blocked while window active
      const blockedCorrect = await app.request('/api/v1/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Forwarded-For': '203.0.113.5' },
        body: JSON.stringify({ username: 'admin', password: 'correct-horse-battery' }),
      });
      expect(blockedCorrect.status).toBe(429);
    } finally {
      ctx.db.close();
    }
  });

  it('auto-bootstraps from env vars, supports PAT Bearer auth, multipart upload, and HTTP Range media streaming', async () => {
    process.env.CHARKLE_ADMIN_USERNAME = 'envadmin';
    process.env.CHARKLE_ADMIN_PASSWORD = 'env-password-1234';
    const { ctx, app } = createTestServer();
    try {
      expect(ctx.auth.isInitialized()).toBe(true);

      // Log in with env-bootstrapped admin
      const loginRes = await app.request('/api/v1/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: 'envadmin', password: 'env-password-1234' }),
      });
      expect(loginRes.status).toBe(200);
      const cookie = extractSessionCookie(loginRes);

      // Create PAT (chk_...)
      const patRes = await app.request('/api/v1/auth/tokens', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Cookie: cookie },
        body: JSON.stringify({ name: 'Claude MCP', scopes: ['read', 'write', 'mcp'] }),
      });
      expect(patRes.status).toBe(201);
      const patData = (await patRes.json()) as { token: string; info: { id: string; prefix: string } };
      expect(patData.token.startsWith('chk_')).toBe(true);
      expect(patData.info.prefix).toBe(patData.token.slice(0, 12));

      // Verify Bearer token works without cookie
      const bearerBoot = await app.request('/api/v1/library/bootstrap', {
        headers: { Authorization: `Bearer ${patData.token}` },
      });
      expect(bearerBoot.status).toBe(200);

      // Upload a PNG via multipart using Bearer PAT
      const pngBuf = await sharp({
        create: { width: 640, height: 480, channels: 4, background: { r: 64, g: 120, b: 196, alpha: 1 } },
      })
        .png()
        .toBuffer();
      const form = new FormData();
      form.append('files', new File([new Uint8Array(pngBuf)], 'studio-test.png', { type: 'image/png' }));

      const uploadRes = await app.request('/api/v1/assets/upload', {
        method: 'POST',
        headers: { Authorization: `Bearer ${patData.token}` },
        body: form,
      });
      expect(uploadRes.status).toBe(201);
      const uploaded = (await uploadRes.json()) as { assets: Array<{ id: string }> };
      const assetID = uploaded.assets[0].id;

      // Media thumbnail requires auth (401 without, 200 with Bearer)
      expect((await app.request(`/api/v1/media/${assetID}/thumbnail/grid520`)).status).toBe(401);
      const thumbRes = await app.request(`/api/v1/media/${assetID}/thumbnail/grid520`, {
        headers: { Authorization: `Bearer ${patData.token}` },
      });
      expect(thumbRes.status).toBe(200);
      expect(thumbRes.headers.get('content-type')).toBe('image/jpeg');

      // HTTP Range 206 Partial Content streaming on original
      const rangeRes = await app.request(`/api/v1/media/${assetID}/original`, {
        headers: {
          Authorization: `Bearer ${patData.token}`,
          Range: 'bytes=0-15',
        },
      });
      expect(rangeRes.status).toBe(206);
      expect(rangeRes.headers.get('content-range')).toMatch(/^bytes 0-15\/\d+$/);
      const partialBytes = new Uint8Array(await rangeRes.arrayBuffer());
      expect(partialBytes.byteLength).toBe(16);
      // PNG magic bytes 89 50 4E 47
      expect(Array.from(partialBytes.subarray(0, 4))).toEqual([0x89, 0x50, 0x4e, 0x47]);

      // Revoke PAT -> immediately rejected with 401
      const delPat = await app.request(`/api/v1/auth/tokens/${patData.info.id}`, {
        method: 'DELETE',
        headers: { Cookie: cookie },
      });
      expect(delPat.status).toBe(200);
      const afterRevoke = await app.request('/api/v1/library/bootstrap', {
        headers: { Authorization: `Bearer ${patData.token}` },
      });
      expect(afterRevoke.status).toBe(401);
    } finally {
      ctx.db.close();
    }
  });

  it('strictly enforces PAT scopes (read, write, mcp) and blocks PATs from admin auth/agent endpoints with 403 (P0-02)', async () => {
    const { ctx, app } = createTestServer();
    try {
      const user = await ctx.auth.setupAdmin('admin', 'strong-password-123');
      const loginRes = await app.request('/api/v1/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: 'admin', password: 'strong-password-123' }),
      });
      const cookie = extractSessionCookie(loginRes);

      const readPat = ctx.auth.createApiToken(user.id, 'read-only', ['read']);
      const mcpPat = ctx.auth.createApiToken(user.id, 'mcp-only', ['mcp']);
      const fullPat = ctx.auth.createApiToken(user.id, 'full-pat', ['read', 'write', 'mcp']);

      // 1. read-only PAT: GET + read-only POST query work (200), write mutations & /mcp return 403
      expect(
        (
          await app.request('/api/v1/library/bootstrap', {
            headers: { Authorization: `Bearer ${readPat.token}` },
          })
        ).status,
      ).toBe(200);
      expect(
        (
          await app.request('/api/v1/assets/query', {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${readPat.token}`,
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({ criteria: {} }),
          })
        ).status,
      ).toBe(200);
      expect(
        (
          await app.request('/api/v1/folders', {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${readPat.token}`,
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({ name: 'ShouldFail' }),
          })
        ).status,
      ).toBe(403);
      expect(
        (
          await app.request('/api/v1/mcp', {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${readPat.token}`,
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }),
          })
        ).status,
      ).toBe(403);

      // 2. mcp-only PAT: /api/v1/mcp allowed (200), standard REST GET /library/bootstrap blocked (403)
      expect(
        (
          await app.request('/api/v1/library/bootstrap', {
            headers: { Authorization: `Bearer ${mcpPat.token}` },
          })
        ).status,
      ).toBe(403);
      expect(
        (
          await app.request('/api/v1/mcp', {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${mcpPat.token}`,
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }),
          })
        ).status,
      ).toBe(200);

      // 3. Even full ['read','write','mcp'] PAT is NEVER allowed to mint/revoke tokens, manage sessions, change password, or mutate /agent/config
      const adminOnlyChecks = [
        app.request('/api/v1/auth/tokens', {
          method: 'POST',
          headers: { Authorization: `Bearer ${fullPat.token}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: 'Escalated', scopes: ['read', 'write', 'mcp'] }),
        }),
        app.request(`/api/v1/auth/tokens/${readPat.info.id}`, {
          method: 'DELETE',
          headers: { Authorization: `Bearer ${fullPat.token}` },
        }),
        app.request('/api/v1/auth/sessions', {
          headers: { Authorization: `Bearer ${fullPat.token}` },
        }),
        app.request('/api/v1/auth/change-password', {
          method: 'POST',
          headers: { Authorization: `Bearer ${fullPat.token}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            currentPassword: 'strong-password-123',
            newPassword: 'another-strong-password',
          }),
        }),
        app.request('/api/v1/agent/config', {
          method: 'PUT',
          headers: { Authorization: `Bearer ${fullPat.token}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ config: { enabled: true, accessLevel: 'readWrite' } }),
        }),
      ];
      const patResults = await Promise.all(adminOnlyChecks);
      for (const r of patResults) {
        expect(r.status).toBe(403);
      }

      // Session cookie retains full admin privilege on all of them
      expect(
        (await app.request('/api/v1/auth/sessions', { headers: { Cookie: cookie } })).status,
      ).toBe(200);
      expect(
        (
          await app.request('/api/v1/agent/config', {
            method: 'PUT',
            headers: { Cookie: cookie, 'Content-Type': 'application/json' },
            body: JSON.stringify({ config: { enabled: true, accessLevel: 'readWrite' } }),
          })
        ).status,
      ).toBe(200);
    } finally {
      ctx.db.close();
    }
  });
});
