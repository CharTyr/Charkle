import React, { useEffect, useMemo, useState } from 'react';
import { Eye, EyeOff, Lock, ShieldCheck, User as UserIcon } from 'lucide-react';
import { Button, CharkleBrandMark, GlassSurface, SkeletonBlock, useDelayedFlag } from '../../design-system';
import { useAuthStore } from '../../stores/authStore';

function evaluatePasswordStrength(password: string): {
  level: 0 | 1 | 2 | 3;
  label: string;
  color: string;
} {
  if (!password) return { level: 0, label: '至少 8 位字符', color: 'var(--text-tertiary)' };
  let score = 0;
  if (password.length >= 8) score++;
  if (password.length >= 12) score++;
  if (/[a-z]/.test(password) && /[A-Z]/.test(password)) score++;
  if (/\d/.test(password) && /[^A-Za-z0-9]/.test(password)) score++;

  if (password.length < 8) return { level: 1, label: '长度不足（需至少 8 位）', color: 'var(--danger)' };
  if (score <= 2) return { level: 1, label: '强度：弱', color: 'var(--warning)' };
  if (score === 3) return { level: 2, label: '强度：良好', color: 'var(--accent)' };
  return { level: 3, label: '强度：强', color: 'var(--success)' };
}

export interface AuthGateProps {
  children: React.ReactNode;
}

export const AuthGate: React.FC<AuthGateProps> = ({ children }) => {
  const {
    initialized,
    authenticated,
    loading,
    submitting,
    error,
    rateLimitUntilMs,
    checkAuth,
    setupAdmin,
    login,
    clearError,
  } = useAuthStore();

  const [username, setUsername] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [rememberMe, setRememberMe] = useState(true);
  const [showPassword, setShowPassword] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const [nowMs, setNowMs] = useState(() => Date.now());

  useEffect(() => {
    void checkAuth();
  }, [checkAuth]);

  useEffect(() => {
    if (!rateLimitUntilMs || rateLimitUntilMs <= Date.now()) return;
    const id = window.setInterval(() => setNowMs(Date.now()), 500);
    return () => window.clearInterval(id);
  }, [rateLimitUntilMs]);

  const countdownSec = useMemo(() => {
    if (!rateLimitUntilMs) return 0;
    return Math.max(0, Math.ceil((rateLimitUntilMs - nowMs) / 1000));
  }, [rateLimitUntilMs, nowMs]);

  const strength = useMemo(() => evaluatePasswordStrength(password), [password]);
  const showLoadingSkeleton = useDelayedFlag(loading, 300, 500);

  if (loading) {
    return (
      <div className="h-full w-full flex flex-col items-center justify-center bg-[var(--bg-gallery)] gap-4">
        <CharkleBrandMark size={48} />
        {showLoadingSkeleton && (
          <div className="flex flex-col items-center gap-2">
            <SkeletonBlock className="w-[120px] h-[6px] rounded-full" />
            <span className="text-[12.5px] text-[var(--text-tertiary)]">正在载入…</span>
          </div>
        )}
      </div>
    );
  }

  if (authenticated) {
    return <>{children}</>;
  }

  const activeError = localError || error;

  const handleSetupSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLocalError(null);
    clearError();

    const trimmedUser = username.trim();
    if (trimmedUser.length < 2) {
      setLocalError('用户名至少需要 2 个字符');
      return;
    }
    if (password.length < 8) {
      setLocalError('管理员密码至少需要 8 位字符');
      return;
    }
    if (password !== confirmPassword) {
      setLocalError('两次输入的密码不一致');
      return;
    }

    await setupAdmin({
      username: trimmedUser,
      displayName: displayName.trim() || trimmedUser,
      password,
    });
  };

  const handleLoginSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (countdownSec > 0) return;
    setLocalError(null);
    clearError();

    if (!username.trim() || !password) {
      setLocalError('请输入用户名和密码');
      return;
    }

    await login({
      username: username.trim(),
      password,
      rememberMe,
    });
  };

  return (
    <div
      className="relative h-full w-full flex items-center justify-center p-6 overflow-y-auto bg-[var(--bg-gallery)]"
      style={{
        backgroundImage:
          'radial-gradient(ellipse 65% 50% at 50% 0%, rgba(42, 96, 224, 0.05) 0%, transparent 70%)',
      }}
    >
      <div className="w-full max-w-[412px] charkle-modal-panel">
        <GlassSurface
          variant="regular"
          radius="dock"
          className="p-7 sm:p-8 flex flex-col gap-6"
        >
          {/* Header */}
          <div className="flex flex-col items-center text-center gap-3">
            <CharkleBrandMark size={52} />
            <h1 className="text-[20px] font-semibold tracking-[-0.02em] text-[var(--text-primary)]">
              {!initialized ? '创建管理员账号' : '登录'}
            </h1>
          </div>

          {!initialized ? (
            <form onSubmit={handleSetupSubmit} className="flex flex-col gap-3.5">
              <div className="flex flex-col gap-1.5">
                <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                  管理员用户名
                </label>
                <div className="relative">
                  <UserIcon
                    size={15}
                    className="absolute left-3 top-1/2 -translate-y-1/2 text-[var(--text-tertiary)] pointer-events-none"
                  />
                  <input
                    type="text"
                    autoComplete="username"
                    autoFocus
                    placeholder="例如 admin 或你的名字"
                    value={username}
                    onChange={(e) => setUsername(e.target.value)}
                    className="w-full h-10 pl-9 pr-3 text-[13.5px] rounded-[var(--radius-dock-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)] focus:ring-2 focus:ring-[var(--accent-ring)]"
                  />
                </div>
              </div>

              <div className="flex flex-col gap-1.5">
                <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                  显示名称（可选）
                </label>
                <input
                  type="text"
                  placeholder="昵称"
                  value={displayName}
                  onChange={(e) => setDisplayName(e.target.value)}
                  className="w-full h-10 px-3 text-[13.5px] rounded-[var(--radius-dock-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)] focus:ring-2 focus:ring-[var(--accent-ring)]"
                />
              </div>

              <div className="flex flex-col gap-1.5">
                <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                  设置密码
                </label>
                <div className="relative">
                  <Lock
                    size={15}
                    className="absolute left-3 top-1/2 -translate-y-1/2 text-[var(--text-tertiary)] pointer-events-none"
                  />
                  <input
                    type={showPassword ? 'text' : 'password'}
                    autoComplete="new-password"
                    placeholder="至少 8 位字符"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    className="w-full h-10 pl-9 pr-10 text-[13.5px] rounded-[var(--radius-dock-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)] focus:ring-2 focus:ring-[var(--accent-ring)]"
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword((v) => !v)}
                    aria-label={showPassword ? '隐藏密码' : '显示密码'}
                    className="absolute right-2.5 top-1/2 -translate-y-1/2 p-1 text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer"
                  >
                    {showPassword ? <EyeOff size={15} /> : <Eye size={15} />}
                  </button>
                </div>

                {/* Strength indicator */}
                <div className="flex items-center gap-2 mt-0.5">
                  <div className="flex-1 flex gap-1 h-1">
                    {[1, 2, 3].map((idx) => (
                      <span
                        key={idx}
                        className="flex-1 rounded-full transition-colors duration-150"
                        style={{
                          backgroundColor:
                            strength.level >= idx ? strength.color : 'var(--border-hairline)',
                        }}
                      />
                    ))}
                  </div>
                  <span className="text-[11px]" style={{ color: strength.color }}>
                    {strength.label}
                  </span>
                </div>
              </div>

              <div className="flex flex-col gap-1.5">
                <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                  确认密码
                </label>
                <input
                  type={showPassword ? 'text' : 'password'}
                  autoComplete="new-password"
                  placeholder="再次输入管理员密码"
                  value={confirmPassword}
                  onChange={(e) => setConfirmPassword(e.target.value)}
                  className="w-full h-10 px-3 text-[13.5px] rounded-[var(--radius-dock-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)] focus:ring-2 focus:ring-[var(--accent-ring)]"
                />
              </div>

              {activeError && (
                <div className="px-3 py-2 rounded-[var(--radius-settings-inner)] bg-[var(--danger-soft)] text-[var(--danger)] text-[12.5px] leading-snug">
                  {activeError}
                </div>
              )}

              <Button
                type="submit"
                variant="primary"
                size="md"
                loading={submitting}
                className="w-full justify-center mt-1 h-10"
              >
                <ShieldCheck size={16} />
                创建管理员账号
              </Button>
            </form>
          ) : (
            <form onSubmit={handleLoginSubmit} className="flex flex-col gap-3.5">
              <div className="flex flex-col gap-1.5">
                <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                  用户名
                </label>
                <div className="relative">
                  <UserIcon
                    size={15}
                    className="absolute left-3 top-1/2 -translate-y-1/2 text-[var(--text-tertiary)] pointer-events-none"
                  />
                  <input
                    type="text"
                    autoComplete="username"
                    autoFocus
                    placeholder="输入管理员用户名"
                    value={username}
                    onChange={(e) => setUsername(e.target.value)}
                    className="w-full h-10 pl-9 pr-3 text-[13.5px] rounded-[var(--radius-dock-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)] focus:ring-2 focus:ring-[var(--accent-ring)]"
                  />
                </div>
              </div>

              <div className="flex flex-col gap-1.5">
                <label className="text-[12px] font-medium text-[var(--text-secondary)]">
                  密码
                </label>
                <div className="relative">
                  <Lock
                    size={15}
                    className="absolute left-3 top-1/2 -translate-y-1/2 text-[var(--text-tertiary)] pointer-events-none"
                  />
                  <input
                    type={showPassword ? 'text' : 'password'}
                    autoComplete="current-password"
                    placeholder="输入密码"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    className="w-full h-10 pl-9 pr-10 text-[13.5px] rounded-[var(--radius-dock-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)] focus:ring-2 focus:ring-[var(--accent-ring)]"
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword((v) => !v)}
                    aria-label={showPassword ? '隐藏密码' : '显示密码'}
                    className="absolute right-2.5 top-1/2 -translate-y-1/2 p-1 text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer"
                  >
                    {showPassword ? <EyeOff size={15} /> : <Eye size={15} />}
                  </button>
                </div>
              </div>

              <label className="flex items-center gap-2 text-[12.5px] text-[var(--text-secondary)] select-none cursor-pointer">
                <input
                  type="checkbox"
                  checked={rememberMe}
                  onChange={(e) => setRememberMe(e.target.checked)}
                  className="h-3.5 w-3.5 rounded accent-[var(--accent)]"
                />
                保持登录 30 天
              </label>

              {activeError && (
                <div className="px-3 py-2 rounded-[var(--radius-settings-inner)] bg-[var(--danger-soft)] text-[var(--danger)] text-[12.5px] leading-snug">
                  {activeError}
                  {countdownSec > 0 && (
                    <span className="font-mono font-semibold ml-1.5">({countdownSec}s)</span>
                  )}
                </div>
              )}

              <Button
                type="submit"
                variant="primary"
                size="md"
                loading={submitting}
                disabled={countdownSec > 0}
                className="w-full justify-center mt-1 h-10"
              >
                {countdownSec > 0 ? `请等待 ${countdownSec} 秒后重试` : '登录'}
              </Button>
            </form>
          )}
        </GlassSurface>
      </div>
    </div>
  );
};
