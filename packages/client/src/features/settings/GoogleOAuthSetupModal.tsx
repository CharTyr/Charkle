import React, { useRef, useState } from 'react';
import { Check, Copy, ExternalLink, FileUp, KeyRound } from 'lucide-react';
import { apiClient } from '../../api/client';
import { ModalShell } from '../../design-system/ModalShell';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import { SETTINGS_LINKS, SettingsButton, SettingsInput } from './SettingsChrome';

export interface GoogleOAuthSetupModalProps {
  open: boolean;
  onClose: () => void;
  autoSignInAfterSave?: boolean;
  onCompleted?: () => void;
}

interface ParsedGoogleSecretJson {
  client_id?: string;
  client_secret?: string;
  installed?: { client_id?: string; client_secret?: string };
  web?: { client_id?: string; client_secret?: string };
}

export const GoogleOAuthSetupModal: React.FC<GoogleOAuthSetupModalProps> = ({
  open,
  onClose,
  autoSignInAfterSave = true,
  onCompleted,
}) => {
  const loadSyncConfig = useSyncAIStore((s) => s.loadSyncConfig);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [clientID, setClientID] = useState('');
  const [clientSecret, setClientSecret] = useState('');
  const [saving, setSaving] = useState(false);
  const [copiedRedirect, setCopiedRedirect] = useState(false);

  const oauthRedirectURI =
    typeof window !== 'undefined'
      ? `${window.location.origin}/api/v1/sync/google/oauth/callback`
      : '/api/v1/sync/google/oauth/callback';

  const handleCopyRedirectURI = async () => {
    try {
      await navigator.clipboard.writeText(oauthRedirectURI);
      setCopiedRedirect(true);
      window.setTimeout(() => setCopiedRedirect(false), 1800);
      pushToast({ tone: 'success', message: '已复制授权回调地址' });
    } catch {
      pushToast({ tone: 'info', message: '请手动选中并复制上方回调地址' });
    }
  };

  const saveAndOptionallySignIn = async (cid: string, secret: string) => {
    setSaving(true);
    try {
      await apiClient.saveGoogleOAuthConfig({
        clientID: cid,
        clientSecret: secret,
      });
      await loadSyncConfig();
      setClientID('');
      setClientSecret('');
      onClose();
      onCompleted?.();

      if (autoSignInAfterSave) {
        try {
          const { authURL } = await apiClient.startGoogleOAuth();
          window.open(authURL, '_blank', 'noopener,noreferrer');
          pushToast({
            tone: 'success',
            message: '凭据已加密保存，已打开 Google 登录授权页',
          });
        } catch (oauthErr) {
          pushToast({
            tone: 'error',
            message: oauthErr instanceof Error ? oauthErr.message : '凭据已保存，但发起 Google 登录失败',
          });
        }
      } else {
        pushToast({ tone: 'success', message: 'Google Drive 登录凭据已安全保存至服务端' });
      }
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '保存 Google 登录凭据失败',
      });
    } finally {
      setSaving(false);
    }
  };

  const handleImportJsonFile = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (!file) return;

    try {
      const raw = await file.text();
      const parsed = JSON.parse(raw) as ParsedGoogleSecretJson;
      const source = parsed.installed ?? parsed.web ?? parsed;
      const cid = (source.client_id ?? '').trim();
      const secret = (source.client_secret ?? '').trim();
      if (!cid || !secret) {
        pushToast({
          tone: 'error',
          message: '该 JSON 文件缺少 client_id 或 client_secret，请确认选择了正确的 Google OAuth 凭据文件',
        });
        return;
      }
      setClientID(cid);
      setClientSecret(secret);
      await saveAndOptionallySignIn(cid, secret);
    } catch {
      pushToast({ tone: 'error', message: '无法解析该 JSON 文件，请检查文件格式' });
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const cid = clientID.trim();
    const secret = clientSecret.trim();
    if (!cid || !secret) return;
    await saveAndOptionallySignIn(cid, secret);
  };

  return (
    <ModalShell
      open={open}
      onClose={() => {
        if (!saving) onClose();
      }}
      width="md"
      title={
        <span className="inline-flex items-center gap-2">
          <KeyRound size={16} />
          配置 Google Drive 登录凭据
        </span>
      }
      subtitle="直连你自己的 Google Drive，仅首次需要配置一次，凭据由服务端加密保存"
      footer={
        <>
          <SettingsButton variant="secondary" disabled={saving} onClick={onClose}>
            取消
          </SettingsButton>
          <SettingsButton
            variant="primary"
            loading={saving}
            disabled={!clientID.trim() || !clientSecret.trim()}
            onClick={(e) => void handleSubmit(e)}
          >
            {autoSignInAfterSave ? '保存并前往 Google 登录' : '保存凭据'}
          </SettingsButton>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        {/* Live OAuth Redirect URI */}
        <div className="p-3 rounded-[10px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] flex flex-col gap-2">
          <div className="flex items-center justify-between gap-2">
            <div className="text-[11.5px] font-medium text-[var(--text-primary)]">
              授权回调地址（已授权的重定向 URI）
            </div>
            <SettingsButton
              variant="secondary"
              onClick={() => void handleCopyRedirectURI()}
              className="shrink-0"
            >
              {copiedRedirect ? <Check size={12} /> : <Copy size={12} />}
              {copiedRedirect ? '已复制' : '复制回调地址'}
            </SettingsButton>
          </div>
          <div className="text-[11px] text-[var(--text-secondary)] leading-relaxed">
            在 Google Cloud 创建 Web 应用凭据时，请将下方地址添加到「已授权的重定向 URI」：
          </div>
          <code className="block w-full px-2.5 py-2 rounded-[7px] bg-[var(--settings-card,var(--bg-elevated))] border border-[var(--settings-border,var(--border-hairline))] font-mono text-[11.5px] leading-relaxed text-[var(--text-primary)] break-all select-all">
            {oauthRedirectURI}
          </code>
        </div>

        {/* Tutorial link + client_secret.json importer */}
        <div className="p-3 rounded-[10px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] flex flex-col gap-2.5">
          <a
            href={SETTINGS_LINKS.googleOAuthGuide}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1.5 text-[12px] font-medium text-[var(--accent)] hover:underline self-start"
          >
            查看 Google Cloud OAuth 凭据 3 分钟图文教程
            <ExternalLink size={11} />
          </a>

          <div className="flex items-center gap-2">
            <input
              ref={fileInputRef}
              type="file"
              accept=".json,application/json"
              onChange={(e) => void handleImportJsonFile(e)}
              className="hidden"
            />
            <SettingsButton
              variant="secondary"
              loading={saving}
              onClick={() => fileInputRef.current?.click()}
            >
              <FileUp size={13} />
              导入 client_secret.json…
            </SettingsButton>
            <span className="text-[11px] text-[var(--text-tertiary)]">
              导入后自动识别并保存
            </span>
          </div>
        </div>

        {/* Manual Client ID / Secret entry */}
        <form onSubmit={(e) => void handleSubmit(e)} className="flex flex-col gap-3">
          <div className="text-[11.5px] font-medium text-[var(--text-secondary)]">
            或手动粘贴凭据信息
          </div>

          <div className="flex flex-col gap-1">
            <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
              Client ID
            </label>
            <SettingsInput
              type="text"
              required
              value={clientID}
              onChange={(e) => setClientID(e.target.value)}
              placeholder="例如：1234567890-xxxx.apps.googleusercontent.com"
              className="w-full"
            />
          </div>

          <div className="flex flex-col gap-1">
            <label className="text-[11.5px] font-medium text-[var(--text-secondary)]">
              Client Secret
            </label>
            <SettingsInput
              type="password"
              required
              value={clientSecret}
              onChange={(e) => setClientSecret(e.target.value)}
              placeholder="例如：GOCSPX-xxxxxxxx"
              className="w-full"
            />
          </div>
        </form>
      </div>
    </ModalShell>
  );
};
