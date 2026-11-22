import React, { useEffect, useState } from 'react';
import {
  Check,
  Copy,
  KeyRound,
  LogOut,
  Monitor,
  Plus,
  ShieldCheck,
  Trash2,
} from 'lucide-react';
import type { ApiTokenScope } from '@charkle/shared';
import { Button } from '../../design-system/Button';
import { useAuthStore } from '../../stores/authStore';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import {
  SettingsCard,
  SettingsDivider,
  SettingsHeader,
  SettingsInput,
} from './SettingsPrimitives';
import { formatRelativeDate } from './shortcuts';

const AVAILABLE_SCOPES: ReadonlyArray<{ id: ApiTokenScope; label: string }> = [
  { id: 'mcp', label: 'MCP 协议' },
  { id: 'read', label: '只读 API' },
  { id: 'write', label: '写入整理' },
  { id: 'sync', label: '同步控制' },
];

export const AccountSecurityTab: React.FC = () => {
  const user = useAuthStore((s) => s.user);
  const sessions = useAuthStore((s) => s.sessions);
  const apiTokens = useAuthStore((s) => s.apiTokens);
  const loadSessions = useAuthStore((s) => s.loadSessions);
  const revokeSession = useAuthStore((s) => s.revokeSession);
  const revokeOtherSessions = useAuthStore((s) => s.revokeOtherSessions);
  const loadApiTokens = useAuthStore((s) => s.loadApiTokens);
  const createApiToken = useAuthStore((s) => s.createApiToken);
  const revokeApiToken = useAuthStore((s) => s.revokeApiToken);
  const changePassword = useAuthStore((s) => s.changePassword);
  const logout = useAuthStore((s) => s.logout);

  const closeSettings = useCoordinatorStore((s) => s.closeSettings);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  // Change password state
  const [currentPassword, setCurrentPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [changingPwd, setChangingPwd] = useState(false);

  // Create PAT state
  const [tokenName, setTokenName] = useState('');
  const [tokenScopes, setTokenScopes] = useState<ApiTokenScope[]>(['mcp', 'read', 'write']);
  const [creatingToken, setCreatingToken] = useState(false);
  const [newlyCreatedToken, setNewlyCreatedToken] = useState<string | null>(null);
  const [copiedNewToken, setCopiedNewToken] = useState(false);

  useEffect(() => {
    void loadSessions();
    void loadApiTokens();
  }, [loadSessions, loadApiTokens]);

  const handleChangePassword = async (e: React.FormEvent) => {
    e.preventDefault();
    if (newPassword.length < 8) {
      pushToast({ tone: 'error', message: '新密码至少需要 8 位字符' });
      return;
    }
    if (newPassword !== confirmPassword) {
      pushToast({ tone: 'error', message: '两次输入的新密码不一致' });
      return;
    }
    setChangingPwd(true);
    try {
      await changePassword(currentPassword, newPassword);
      setCurrentPassword('');
      setNewPassword('');
      setConfirmPassword('');
      pushToast({ tone: 'success', message: '密码已更新，其余设备会话已自动注销' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '修改密码失败',
      });
    } finally {
      setChangingPwd(false);
    }
  };

  const handleCreateToken = async (e: React.FormEvent) => {
    e.preventDefault();
    const name = tokenName.trim();
    if (!name) return;
    setCreatingToken(true);
    try {
      const res = await createApiToken({
        name,
        scopes: tokenScopes.length > 0 ? tokenScopes : ['mcp', 'read'],
      });
      setNewlyCreatedToken(res.token);
      setTokenName('');
      pushToast({ tone: 'success', message: '已签发个人访问令牌，请立即复制保存' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '创建访问令牌失败',
      });
    } finally {
      setCreatingToken(false);
    }
  };

  const handleCopyToken = (token: string) => {
    void navigator.clipboard?.writeText(token);
    setCopiedNewToken(true);
    pushToast({ tone: 'success', message: '已复制 Bearer 令牌到剪贴板' });
    window.setTimeout(() => setCopiedNewToken(false), 1800);
  };

  const toggleScope = (scope: ApiTokenScope) => {
    setTokenScopes((prev) =>
      prev.includes(scope) ? prev.filter((s) => s !== scope) : [...prev, scope],
    );
  };

  return (
    <div className="flex flex-col gap-5">
      <SettingsHeader
        title="账号与安全"
        subtitle="管理当前管理员身份、登录密码、多设备会话及用于外部 MCP / API 接入的个人访问令牌。"
      />

      {/* Current Admin Card */}
      <SettingsCard>
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div className="flex items-center gap-3.5 min-w-0">
            <div className="w-11 h-11 rounded-full bg-[var(--accent-soft)] border border-[var(--accent-ring)] text-[var(--accent)] font-semibold text-[16px] flex items-center justify-center shrink-0">
              {(user?.displayName || user?.username || 'A').slice(0, 1).toUpperCase()}
            </div>
            <div className="min-w-0">
              <div className="flex items-center gap-2">
                <span className="text-[14px] font-semibold text-[var(--text-primary)] truncate">
                  {user?.displayName || user?.username || '管理员'}
                </span>
                <span className="px-2 py-0.5 rounded-full bg-[var(--success-soft)] text-[var(--success)] text-[10.5px] font-semibold inline-flex items-center gap-1">
                  <ShieldCheck size={11} />
                  {user?.role === 'owner' ? '所有者' : '管理员'}
                </span>
              </div>
              <div className="text-[11.5px] text-[var(--text-secondary)] mt-0.5">
                账号 @{user?.username ?? 'admin'} · 最近登录 {formatRelativeDate(user?.lastLoginAt)}
              </div>
            </div>
          </div>

          <Button
            variant="danger"
            size="sm"
            onClick={() => {
              closeSettings();
              void logout();
            }}
          >
            <LogOut size={13} />
            退出登录
          </Button>
        </div>
      </SettingsCard>

      {/* Change Password */}
      <SettingsCard title="修改登录密码">
        <form onSubmit={handleChangePassword} className="flex flex-col gap-3">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-2.5">
            <SettingsInput
              type="password"
              required
              autoComplete="current-password"
              value={currentPassword}
              onChange={(e) => setCurrentPassword(e.target.value)}
              placeholder="当前密码"
            />
            <SettingsInput
              type="password"
              required
              minLength={8}
              autoComplete="new-password"
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
              placeholder="新密码（至少 8 位）"
            />
            <SettingsInput
              type="password"
              required
              minLength={8}
              autoComplete="new-password"
              value={confirmPassword}
              onChange={(e) => setConfirmPassword(e.target.value)}
              placeholder="再次确认新密码"
            />
          </div>
          <div className="flex items-center justify-between gap-2">
            <span className="text-[11.5px] text-[var(--text-tertiary)]">
              密码采用加盐 scrypt 哈希存储；修改后将自动撤销除当前设备外的所有会话。
            </span>
            <Button
              type="submit"
              variant="secondary"
              size="sm"
              loading={changingPwd}
              disabled={!currentPassword || !newPassword || !confirmPassword}
            >
              更新密码
            </Button>
          </div>
        </form>
      </SettingsCard>

      {/* Active Sessions */}
      <SettingsCard
        title={`活跃登录会话 (${sessions.length})`}
        badge={
          sessions.length > 1 ? (
            <Button
              variant="ghost"
              size="xs"
              onClick={async () => {
                await revokeOtherSessions();
                pushToast({ tone: 'success', message: '已注销其他全部设备会话' });
              }}
            >
              注销其他全部设备
            </Button>
          ) : null
        }
      >
        {sessions.length === 0 ? (
          <div className="text-[12px] text-[var(--text-secondary)]">暂无活跃会话记录</div>
        ) : (
          <div className="flex flex-col divide-y divide-[var(--border-hairline)]">
            {sessions.map((session) => (
              <div
                key={session.id}
                className="py-2.5 first:pt-0 last:pb-0 flex items-center justify-between gap-3"
              >
                <div className="flex items-start gap-2.5 min-w-0">
                  <Monitor size={15} className="text-[var(--text-secondary)] mt-0.5 shrink-0" />
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <span className="text-[12.5px] font-medium text-[var(--text-primary)] truncate max-w-[320px]">
                        {session.userAgent || '未知浏览器设备'}
                      </span>
                      {session.isCurrent && (
                        <span className="px-1.5 py-0.5 rounded-[5px] bg-[var(--accent-soft)] text-[var(--accent)] text-[10px] font-semibold shrink-0">
                          当前设备
                        </span>
                      )}
                    </div>
                    <div className="text-[11px] text-[var(--text-tertiary)] mt-0.5">
                      IP {session.ipAddress || '未知'} · 最近活跃 {formatRelativeDate(session.lastSeenAt)} ·
                      到期 {formatRelativeDate(session.expiresAt)}
                    </div>
                  </div>
                </div>

                {!session.isCurrent && (
                  <Button
                    variant="ghost"
                    size="xs"
                    onClick={async () => {
                      await revokeSession(session.id);
                      pushToast({ tone: 'info', message: '已注销该设备会话' });
                    }}
                  >
                    注销
                  </Button>
                )}
              </div>
            ))}
          </div>
        )}
      </SettingsCard>

      {/* Personal Access Tokens (MCP / API Bearer chk_...) */}
      <SettingsCard title="个人访问令牌 (MCP / API Bearer)">
        <p className="text-[12px] text-[var(--text-secondary)] leading-relaxed">
          签发 <code className="font-mono text-[11.5px]">chk_...</code> 格式的 Bearer 令牌，供 Claude Desktop、Cursor、Antigravity 或自动化脚本访问 HTTP MCP 与 REST API。
        </p>

        {/* Copy-once newly created token banner */}
        {newlyCreatedToken && (
          <div className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--success-soft)] border border-[var(--success)]/35 flex flex-col gap-2">
            <div className="flex items-center justify-between gap-2">
              <span className="text-[12px] font-semibold text-[var(--success)]">
                令牌已生成（仅此一次展示完整明文，请立即复制保存）
              </span>
              <button
                type="button"
                onClick={() => setNewlyCreatedToken(null)}
                className="text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
              >
                我知道了
              </button>
            </div>
            <div className="flex items-center gap-2">
              <code className="flex-1 px-2.5 py-1.5 rounded-[6px] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] font-mono text-[11.5px] text-[var(--text-primary)] break-all select-all">
                {newlyCreatedToken}
              </code>
              <Button
                variant="primary"
                size="xs"
                onClick={() => handleCopyToken(newlyCreatedToken)}
              >
                {copiedNewToken ? <Check size={12} /> : <Copy size={12} />}
                {copiedNewToken ? '已复制' : '复制'}
              </Button>
            </div>
          </div>
        )}

        <form onSubmit={handleCreateToken} className="flex flex-col gap-2.5">
          <div className="flex flex-wrap items-center gap-2">
            <SettingsInput
              type="text"
              value={tokenName}
              onChange={(e) => setTokenName(e.target.value)}
              placeholder="令牌备注（如：Cursor MCP、自动化脚本）"
              className="flex-1 min-w-[200px]"
            />
            <Button
              type="submit"
              variant="primary"
              size="sm"
              loading={creatingToken}
              disabled={!tokenName.trim()}
            >
              <Plus size={13} />
              创建令牌
            </Button>
          </div>
          <div className="flex flex-wrap items-center gap-2 text-[11.5px]">
            <span className="text-[var(--text-tertiary)]">权限范围：</span>
            {AVAILABLE_SCOPES.map((sc) => {
              const active = tokenScopes.includes(sc.id);
              return (
                <button
                  key={sc.id}
                  type="button"
                  onClick={() => toggleScope(sc.id)}
                  className={[
                    'charkle-pressable px-2 py-0.5 rounded-[6px] border text-[11px] cursor-pointer',
                    active
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)] border-[var(--accent-ring)] font-medium'
                      : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)] border-[var(--border-hairline)]',
                  ].join(' ')}
                >
                  {sc.label}
                </button>
              );
            })}
          </div>
        </form>

        {apiTokens.length > 0 && (
          <>
            <SettingsDivider />
            <div className="flex flex-col divide-y divide-[var(--border-hairline)]">
              {apiTokens.map((t) => (
                <div
                  key={t.id}
                  className="py-2.5 first:pt-0 last:pb-0 flex items-center justify-between gap-3"
                >
                  <div className="flex items-start gap-2.5 min-w-0">
                    <KeyRound size={14} className="text-[var(--text-secondary)] mt-0.5 shrink-0" />
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <span className="text-[12.5px] font-medium text-[var(--text-primary)] truncate">
                          {t.name}
                        </span>
                        <code className="px-1.5 py-0.5 rounded bg-[var(--bg-subtle)] font-mono text-[10.5px] text-[var(--text-secondary)]">
                          {t.prefix}…
                        </code>
                      </div>
                      <div className="text-[11px] text-[var(--text-tertiary)] mt-0.5">
                        范围：{t.scopes.join(', ')} · 创建于 {formatRelativeDate(t.createdAt)} ·
                        最近使用 {formatRelativeDate(t.lastUsedAt)}
                      </div>
                    </div>
                  </div>
                  <Button
                    variant="ghost"
                    size="xs"
                    onClick={async () => {
                      await revokeApiToken(t.id);
                      pushToast({ tone: 'info', message: `已撤销令牌「${t.name}」` });
                    }}
                  >
                    <Trash2 size={12} className="text-[var(--danger)]" />
                    撤销
                  </Button>
                </div>
              ))}
            </div>
          </>
        )}
      </SettingsCard>
    </div>
  );
};
