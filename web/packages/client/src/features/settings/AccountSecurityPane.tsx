import React, { useEffect, useState } from 'react';
import {
  Check,
  Copy,
  KeyRound,
  LogOut,
  Monitor,
  Plus,
  Trash2,
} from 'lucide-react';
import type { ApiTokenScope, UUID } from '@charkle/shared';
import { ConfirmDialog } from '../../design-system';
import { useAuthStore } from '../../stores/authStore';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import {
  SettingsButton,
  SettingsCardDivider,
  SettingsInput,
  SettingsRow,
  SettingsSection,
  SettingsStatusBadge,
} from './SettingsChrome';
import { formatRelativeDate } from './shortcuts';

const AVAILABLE_SCOPES: ReadonlyArray<{ id: ApiTokenScope; label: string }> = [
  { id: 'mcp', label: 'MCP 工具' },
  { id: 'read', label: '只读访问' },
  { id: 'write', label: '写入整理' },
  { id: 'sync', label: '同步控制' },
];

export const AccountSecurityPane: React.FC = () => {
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

  const [currentPassword, setCurrentPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [changingPwd, setChangingPwd] = useState(false);

  const [tokenName, setTokenName] = useState('');
  const [tokenScopes, setTokenScopes] = useState<ApiTokenScope[]>(['mcp', 'read', 'write']);
  const [creatingToken, setCreatingToken] = useState(false);
  const [newlyCreatedToken, setNewlyCreatedToken] = useState<string | null>(null);
  const [copiedNewToken, setCopiedNewToken] = useState(false);
  const [confirmAction, setConfirmAction] = useState<
    | { type: 'revokeOtherSessions' }
    | { type: 'revokeSession'; id: UUID; label: string }
    | { type: 'revokeToken'; id: UUID; name: string }
    | null
  >(null);

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
      pushToast({ tone: 'success', message: '密码已更新，其他设备会话已自动注销' });
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
      pushToast({ tone: 'success', message: '已创建访问令牌，请立即复制保存' });
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
    pushToast({ tone: 'success', message: '已复制访问令牌' });
    window.setTimeout(() => setCopiedNewToken(false), 1800);
  };

  const toggleScope = (scope: ApiTokenScope) => {
    setTokenScopes((prev) =>
      prev.includes(scope) ? prev.filter((s) => s !== scope) : [...prev, scope],
    );
  };

  return (
    <div className="flex flex-col gap-[22px]">
      {/* Current Admin Account */}
      <SettingsSection title="当前账号">
        <div className="px-4 py-3.5 flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-3 min-w-0">
            <div className="w-10 h-10 rounded-full bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] text-[var(--text-primary)] font-semibold text-[15px] flex items-center justify-center shrink-0">
              {(user?.displayName || user?.username || 'A').slice(0, 1).toUpperCase()}
            </div>
            <div className="min-w-0">
              <div className="flex items-center gap-2">
                <span className="text-[13.5px] font-semibold text-[var(--text-primary)] truncate">
                  {user?.displayName || user?.username || '管理员'}
                </span>
                <SettingsStatusBadge
                  text={user?.role === 'owner' ? '所有者' : '管理员'}
                  tone="positive"
                />
              </div>
              <div className="text-[11.5px] text-[var(--text-secondary)] mt-0.5">
                @{user?.username ?? 'admin'} · 最近登录 {formatRelativeDate(user?.lastLoginAt)}
              </div>
            </div>
          </div>

          <SettingsButton
            variant="destructive"
            onClick={() => {
              closeSettings();
              void logout();
            }}
          >
            <LogOut size={13} />
            退出登录
          </SettingsButton>
        </div>
      </SettingsSection>

      {/* Change Password */}
      <SettingsSection title="修改登录密码">
        <form onSubmit={handleChangePassword} className="p-4 flex flex-col gap-3">
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
              placeholder="确认新密码"
            />
          </div>
          <div className="flex items-center justify-between gap-2">
            <span className="text-[11px] text-[var(--text-secondary)]">
              修改后需在其他设备重新登录
            </span>
            <SettingsButton
              type="submit"
              variant="secondary"
              loading={changingPwd}
              disabled={!currentPassword || !newPassword || !confirmPassword}
            >
              更新密码
            </SettingsButton>
          </div>
        </form>
      </SettingsSection>

      {/* Active Sessions */}
      <SettingsSection title={`活跃登录会话 (${sessions.length})`}>
        {sessions.length > 1 && (
          <>
            <SettingsRow title="多设备会话管理">
              <SettingsButton
                variant="secondary"
                onClick={() => setConfirmAction({ type: 'revokeOtherSessions' })}
              >
                注销其他设备
              </SettingsButton>
            </SettingsRow>
            <SettingsCardDivider />
          </>
        )}

        {sessions.length === 0 ? (
          <div className="px-4 py-3.5 text-[12px] text-[var(--text-secondary)]">
            暂无活跃会话记录
          </div>
        ) : (
          <div className="flex flex-col">
            {sessions.map((session, idx) => (
              <React.Fragment key={session.id}>
                {idx > 0 && <SettingsCardDivider />}
                <div className="px-4 py-3 flex items-center justify-between gap-3">
                  <div className="flex items-start gap-2.5 min-w-0">
                    <Monitor size={14} className="text-[var(--text-secondary)] mt-0.5 shrink-0" />
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <span className="text-[12.5px] font-medium text-[var(--text-primary)] truncate max-w-[300px]">
                          {session.userAgent || '未知浏览器设备'}
                        </span>
                        {session.isCurrent && <SettingsStatusBadge text="当前设备" tone="positive" />}
                      </div>
                      <div className="text-[11px] text-[var(--text-secondary)] mt-0.5">
                        IP {session.ipAddress || '未知'} · 最近活跃 {formatRelativeDate(session.lastSeenAt)} ·
                        到期 {formatRelativeDate(session.expiresAt)}
                      </div>
                    </div>
                  </div>
                  {!session.isCurrent && (
                    <SettingsButton
                      variant="secondary"
                      onClick={() =>
                        setConfirmAction({
                          type: 'revokeSession',
                          id: session.id,
                          label: session.userAgent || '该设备',
                        })
                      }
                    >
                      注销
                    </SettingsButton>
                  )}
                </div>
              </React.Fragment>
            ))}
          </div>
        )}
      </SettingsSection>

      {/* Personal Access Tokens */}
      <SettingsSection title="访问令牌" caption="用于浏览器扩展与外部 AI 助手">
        <div className="p-4 flex flex-col gap-3">
          {newlyCreatedToken && (
            <div className="p-3 rounded-[9px] bg-[var(--success-soft)] border border-[var(--settings-positive,var(--success))]/30 flex flex-col gap-2">
              <div className="flex items-center justify-between gap-2">
                <span className="text-[12px] font-semibold text-[var(--settings-positive,var(--success))]">
                  请立即复制保存，关闭后不再显示
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
                <code className="flex-1 px-2.5 py-1.5 rounded-[var(--radius-settings-inner)] bg-[var(--settings-card,var(--bg-elevated))] border border-[var(--settings-border,var(--border-hairline))] font-mono text-[11.5px] text-[var(--text-primary)] charkle-wrap-anywhere select-all">
                  {newlyCreatedToken}
                </code>
                <SettingsButton variant="primary" onClick={() => handleCopyToken(newlyCreatedToken)}>
                  {copiedNewToken ? <Check size={12} /> : <Copy size={12} />}
                  {copiedNewToken ? '已复制' : '复制'}
                </SettingsButton>
              </div>
            </div>
          )}

          <form onSubmit={handleCreateToken} className="flex flex-col gap-2.5">
            <div className="flex flex-wrap items-center gap-2">
              <SettingsInput
                type="text"
                value={tokenName}
                onChange={(e) => setTokenName(e.target.value)}
                placeholder="令牌名称"
                className="flex-1 min-w-[200px]"
              />
              <SettingsButton
                type="submit"
                variant="primary"
                loading={creatingToken}
                disabled={!tokenName.trim()}
              >
                <Plus size={13} />
                创建令牌
              </SettingsButton>
            </div>
            <div className="flex flex-wrap items-center gap-1.5 text-[11px]">
              <span className="text-[var(--text-secondary)]">权限范围：</span>
              {AVAILABLE_SCOPES.map((sc) => {
                const active = tokenScopes.includes(sc.id);
                return (
                  <button
                    key={sc.id}
                    type="button"
                    onClick={() => toggleScope(sc.id)}
                    className={[
                      'charkle-pressable px-2 py-0.5 rounded-[6px] border text-[11px] cursor-pointer transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]',
                      active
                        ? 'bg-[var(--accent-soft)] text-[var(--accent)] border-[var(--accent-ring)] font-medium'
                        : 'bg-[var(--settings-subtle,var(--bg-subtle))] text-[var(--text-secondary)] border-[var(--settings-border,var(--border-hairline))]',
                    ].join(' ')}
                  >
                    {sc.label}
                  </button>
                );
              })}
            </div>
          </form>
        </div>

        {apiTokens.length > 0 && (
          <>
            <SettingsCardDivider />
            <div className="flex flex-col">
              {apiTokens.map((t, idx) => (
                <React.Fragment key={t.id}>
                  {idx > 0 && <SettingsCardDivider />}
                  <div className="px-4 py-3 flex items-center justify-between gap-3">
                    <div className="flex items-start gap-2.5 min-w-0">
                      <KeyRound size={14} className="text-[var(--text-secondary)] mt-0.5 shrink-0" />
                      <div className="min-w-0">
                        <div className="flex items-center gap-2">
                          <span className="text-[12.5px] font-medium text-[var(--text-primary)] truncate">
                            {t.name}
                          </span>
                          <code className="px-1.5 py-0.5 rounded-[var(--radius-chip)] bg-[var(--settings-subtle,var(--bg-subtle))] font-mono text-[10.5px] text-[var(--text-secondary)]">
                            {t.prefix}…
                          </code>
                        </div>
                        <div className="text-[11px] text-[var(--text-secondary)] mt-0.5">
                          范围：{t.scopes.join(', ')} · 创建于 {formatRelativeDate(t.createdAt)} ·
                          最近使用 {formatRelativeDate(t.lastUsedAt)}
                        </div>
                      </div>
                    </div>
                    <SettingsButton
                      variant="destructive"
                      onClick={() =>
                        setConfirmAction({
                          type: 'revokeToken',
                          id: t.id,
                          name: t.name,
                        })
                      }
                    >
                      <Trash2 size={12} />
                      撤销
                    </SettingsButton>
                  </div>
                </React.Fragment>
              ))}
            </div>
          </>
        )}
      </SettingsSection>

      <ConfirmDialog
        open={confirmAction !== null}
        onClose={() => setConfirmAction(null)}
        tone="danger"
        title={
          confirmAction?.type === 'revokeToken'
            ? `撤销访问令牌「${confirmAction.name}」？`
            : confirmAction?.type === 'revokeOtherSessions'
              ? '注销其他全部设备？'
              : '注销该设备会话？'
        }
        description={
          confirmAction?.type === 'revokeToken'
            ? '撤销后，使用此令牌的扩展或外部助手将立即失去访问权限。'
            : confirmAction?.type === 'revokeOtherSessions'
              ? '其他已登录设备将需要重新输入密码登录。'
              : confirmAction?.type === 'revokeSession'
                ? `设备「${confirmAction.label}」将需要重新登录。`
                : undefined
        }
        confirmLabel={confirmAction?.type === 'revokeToken' ? '确认撤销' : '确认注销'}
        onConfirm={async () => {
          if (!confirmAction) return;
          if (confirmAction.type === 'revokeToken') {
            await revokeApiToken(confirmAction.id);
            pushToast({ tone: 'info', message: `已撤销令牌「${confirmAction.name}」` });
          } else if (confirmAction.type === 'revokeOtherSessions') {
            await revokeOtherSessions();
            pushToast({ tone: 'success', message: '已注销其他全部设备会话' });
          } else if (confirmAction.type === 'revokeSession') {
            await revokeSession(confirmAction.id);
            pushToast({ tone: 'info', message: '已注销该设备会话' });
          }
        }}
      />
    </div>
  );
};
