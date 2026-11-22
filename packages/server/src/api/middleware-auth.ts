import type { Context, MiddlewareHandler } from 'hono';
import { getCookie } from 'hono/cookie';
import type { AuthenticatedPrincipal, ServerContext } from '../context.js';

export type AppVariables = {
  principal: AuthenticatedPrincipal | null;
};

const PUBLIC_API_ROUTES: ReadonlyArray<{ method: string; path: string }> = [
  { method: 'GET', path: '/api/v1/health' },
  { method: 'GET', path: '/api/v1/auth/status' },
  { method: 'POST', path: '/api/v1/auth/setup' },
  { method: 'POST', path: '/api/v1/auth/login' },
];

export function isPublicApiRoute(method: string, pathname: string): boolean {
  const upper = method.toUpperCase();
  return PUBLIC_API_ROUTES.some((r) => r.method === upper && r.path === pathname);
}

export function extractRequestPrincipal(
  c: Context,
  ctx: ServerContext,
): AuthenticatedPrincipal | null {
  // 1. Authorization: Bearer chk_...
  const authHeader = c.req.header('authorization');
  if (authHeader && authHeader.toLowerCase().startsWith('bearer ')) {
    const token = authHeader.slice(7).trim();
    const principal = ctx.auth.verifyApiToken(token);
    if (principal) return principal;
  }

  // 2. HttpOnly Session Cookie
  const sessionCookie = getCookie(c, ctx.auth.sessionCookieName);
  if (sessionCookie) {
    const principal = ctx.auth.verifySessionToken(sessionCookie);
    if (principal) return principal;
  }

  return null;
}

export function isSecureRequest(c: Context): boolean {
  const proto = c.req.header('x-forwarded-proto');
  if (proto && proto.toLowerCase().split(',')[0].trim() === 'https') {
    return true;
  }
  return c.req.url.startsWith('https://');
}

export function getClientIP(c: Context): string {
  const forwarded = c.req.header('x-forwarded-for');
  if (forwarded) {
    const first = forwarded.split(',')[0].trim();
    if (first) return first;
  }
  const realIP = c.req.header('x-real-ip');
  if (realIP) return realIP.trim();
  return '127.0.0.1';
}

export function createSecurityHeadersMiddleware(): MiddlewareHandler {
  return async (c, next) => {
    await next();
    c.header('X-Content-Type-Options', 'nosniff');
    if (!c.res.headers.has('X-Frame-Options')) {
      c.header('X-Frame-Options', 'DENY');
    }
    c.header('Referrer-Policy', 'same-origin');
  };
}

/**
 * Strictly enforces session cookie OR Bearer PAT authentication on ALL `/api/v1/*` routes
 * except `/api/v1/health`, `/api/v1/auth/status`, `/api/v1/auth/setup`, `/api/v1/auth/login`.
 */
export function createAuthMiddleware(ctx: ServerContext): MiddlewareHandler<{
  Variables: AppVariables;
}> {
  return async (c, next) => {
    const pathname = new URL(c.req.url).pathname;
    if (!pathname.startsWith('/api/v1/')) {
      return next();
    }

    const principal = extractRequestPrincipal(c, ctx);
    c.set('principal', principal);

    if (isPublicApiRoute(c.req.method, pathname)) {
      return next();
    }

    if (!principal) {
      return c.json(
        {
          error: '未登录或登录已过期，请先登录 Charkle。',
          code: 'UNAUTHORIZED',
        },
        401,
      );
    }

    return next();
  };
}
