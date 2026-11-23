import { create } from 'zustand';
import type {
  ApiTokenInfo,
  AuthSessionInfo,
  AuthStatus,
  AuthUser,
  CreateApiTokenRequest,
  CreateApiTokenResult,
} from '@charkle/shared';
import { ApiError, apiClient, setUnauthorizedHandler } from '../api/client';

interface AuthState {
  status: AuthStatus | null;
  initialized: boolean;
  authenticated: boolean;
  user: AuthUser | null;
  sessionCount: number;
  loading: boolean;
  submitting: boolean;
  error: string | null;
  rateLimitUntilMs: number | null;
  sessions: AuthSessionInfo[];
  apiTokens: ApiTokenInfo[];

  checkAuth: () => Promise<AuthStatus | null>;
  setupAdmin: (payload: { username: string; password: string; displayName?: string }) => Promise<boolean>;
  login: (payload: { username: string; password: string; rememberMe?: boolean }) => Promise<boolean>;
  logout: () => Promise<void>;
  handleUnauthorized: () => void;
  clearError: () => void;

  loadSessions: () => Promise<void>;
  revokeSession: (sessionId: string) => Promise<void>;
  revokeOtherSessions: () => Promise<void>;

  loadApiTokens: () => Promise<void>;
  createApiToken: (req: CreateApiTokenRequest) => Promise<CreateApiTokenResult>;
  revokeApiToken: (tokenId: string) => Promise<void>;
  changePassword: (currentPassword: string, newPassword: string) => Promise<void>;
}

export const useAuthStore = create<AuthState>((set, get) => ({
  status: null,
  initialized: true,
  authenticated: false,
  user: null,
  sessionCount: 0,
  loading: true,
  submitting: false,
  error: null,
  rateLimitUntilMs: null,
  sessions: [],
  apiTokens: [],

  checkAuth: async () => {
    set({ loading: true, error: null });
    try {
      const status = await apiClient.getAuthStatus();
      set({
        status,
        initialized: status.initialized,
        authenticated: status.authenticated,
        user: status.user,
        sessionCount: status.sessionCount,
        loading: false,
      });
      return status;
    } catch (err) {
      const message = err instanceof Error ? err.message : '无法连接至 Charkle 服务';
      set({ loading: false, error: message });
      return null;
    }
  },

  setupAdmin: async (payload) => {
    set({ submitting: true, error: null });
    try {
      const res = await apiClient.setupAdmin(payload);
      set({
        status: res.status,
        initialized: res.status.initialized,
        authenticated: res.status.authenticated,
        user: res.user,
        sessionCount: res.status.sessionCount,
        submitting: false,
        error: null,
      });
      return true;
    } catch (err) {
      const message = err instanceof Error ? err.message : '初始化管理员账号失败';
      set({ submitting: false, error: message });
      return false;
    }
  },

  login: async (payload) => {
    set({ submitting: true, error: null });
    try {
      const res = await apiClient.login(payload);
      set({
        status: res.status,
        initialized: res.status.initialized,
        authenticated: res.status.authenticated,
        user: res.user,
        sessionCount: res.status.sessionCount,
        submitting: false,
        error: null,
        rateLimitUntilMs: null,
      });
      return true;
    } catch (err) {
      if (err instanceof ApiError && err.status === 429) {
        const retrySec = err.retryAfterSeconds ?? 60;
        set({
          submitting: false,
          rateLimitUntilMs: Date.now() + retrySec * 1000,
          error: err.message || `登录尝试过于频繁，请在 ${retrySec} 秒后重试`,
        });
        return false;
      }
      const message = err instanceof Error ? err.message : '用户名或密码不正确';
      set({ submitting: false, error: message });
      return false;
    }
  },

  logout: async () => {
    try {
      await apiClient.logout();
    } catch {
      // Clear client state even if server session already expired
    }
    set({
      authenticated: false,
      user: null,
      sessions: [],
      apiTokens: [],
      error: null,
    });
  },

  handleUnauthorized: () => {
    if (!get().authenticated) return;
    set({
      authenticated: false,
      user: null,
      error: '会话已过期，请重新登录',
    });
  },

  clearError: () => set({ error: null }),

  loadSessions: async () => {
    const res = await apiClient.listSessions();
    set({ sessions: res.sessions, sessionCount: res.sessions.length });
  },

  revokeSession: async (sessionId) => {
    await apiClient.revokeSession(sessionId);
    await get().loadSessions();
  },

  revokeOtherSessions: async () => {
    await apiClient.revokeOtherSessions();
    await get().loadSessions();
  },

  loadApiTokens: async () => {
    const res = await apiClient.listApiTokens();
    set({ apiTokens: res.tokens });
  },

  createApiToken: async (req) => {
    const res = await apiClient.createApiToken(req);
    set((s) => ({ apiTokens: [res.info, ...s.apiTokens] }));
    return res;
  },

  revokeApiToken: async (tokenId) => {
    await apiClient.revokeApiToken(tokenId);
    set((s) => ({ apiTokens: s.apiTokens.filter((t) => t.id !== tokenId) }));
  },

  changePassword: async (currentPassword, newPassword) => {
    await apiClient.changePassword({ currentPassword, newPassword });
    await get().loadSessions();
  },
}));

setUnauthorizedHandler(() => {
  useAuthStore.getState().handleUnauthorized();
});
