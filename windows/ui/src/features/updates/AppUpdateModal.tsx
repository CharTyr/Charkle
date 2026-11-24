import React, { useMemo } from 'react';
import DOMPurify from 'dompurify';
import { marked } from 'marked';
import {
  ArrowClockwise16Regular,
  ArrowDownload16Regular,
  CheckmarkCircle20Regular,
  Dismiss16Regular,
  ErrorCircle20Regular,
  FolderOpen16Regular,
  Open16Regular,
  ShieldCheckmark16Regular,
  Warning20Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import { Button, CharkleBrandMark, ModalShell } from '../../design-system';
import {
  formatByteCount,
  formatRelativeCheckTime,
  useAppUpdateStore,
} from '../../stores';
import type { AppReleaseUpdate } from '../../types/domain';

function formatPublishedDate(iso?: string | null): string | null {
  if (!iso) return null;
  const parsed = new Date(iso);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toLocaleDateString('zh-CN', {
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
  });
}

function renderSafeMarkdown(raw: string): string {
  const source = raw.trim();
  if (!source) return '';
  const html = marked.parse(source, { async: false, gfm: true, breaks: true }) as string;
  return DOMPurify.sanitize(html, {
    ALLOWED_TAGS: [
      'h1',
      'h2',
      'h3',
      'h4',
      'p',
      'ul',
      'ol',
      'li',
      'strong',
      'em',
      'code',
      'pre',
      'blockquote',
      'hr',
      'br',
      'a',
    ],
    ALLOWED_ATTR: ['href', 'title'],
  });
}

function getActiveUpdate(
  state: ReturnType<typeof useAppUpdateStore.getState>['state'],
): AppReleaseUpdate | null {
  switch (state.status) {
    case 'available':
    case 'downloading':
    case 'verifying':
    case 'readyToInstall':
    case 'installing':
    case 'manualInstallRequired':
      return state.update;
    case 'failed':
      return state.update ?? null;
    default:
      return null;
  }
}

function shortSha256(hash: string): string {
  const clean = hash.trim();
  if (clean.length <= 18) return clean;
  return `${clean.slice(0, 10)}…${clean.slice(-6)}`;
}

/**
 * Fluent 2 native in-app software update dialog mirroring macOS `AppUpdateSheetView.swift`:
 * - Displays version transition pill (`vX → vY · size · date`) and sanitized Markdown release notes
 * - Live streaming download progress, SHA-256 + Windows PE verification badge, and one-click
 *   NSIS passive upgrade & auto-relaunch (`/P /UPDATE /R`) with manual fallback controls
 */
export const AppUpdateModal: React.FC = () => {
  const open = useAppUpdateStore((s) => s.sheetOpen);
  const state = useAppUpdateStore((s) => s.state);
  const currentVersion = useAppUpdateStore((s) => s.currentVersion);
  const closeSheet = useAppUpdateStore((s) => s.closeSheet);
  const checkForUpdatesManually = useAppUpdateStore((s) => s.checkForUpdatesManually);
  const startDownload = useAppUpdateStore((s) => s.startDownload);
  const cancelDownload = useAppUpdateStore((s) => s.cancelDownload);
  const installAndRelaunch = useAppUpdateStore((s) => s.installAndRelaunch);
  const openDownloadedInstaller = useAppUpdateStore((s) => s.openDownloadedInstaller);
  const revealDownloadedInstaller = useAppUpdateStore((s) => s.revealDownloadedInstaller);
  const skipCurrentUpdate = useAppUpdateStore((s) => s.skipCurrentUpdate);
  const openReleasePage = useAppUpdateStore((s) => s.openReleasePage);

  const activeUpdate = getActiveUpdate(state);

  const renderedNotesHtml = useMemo(
    () => (activeUpdate?.releaseNotes ? renderSafeMarkdown(activeUpdate.releaseNotes) : ''),
    [activeUpdate?.releaseNotes],
  );

  const headerTitle = (() => {
    switch (state.status) {
      case 'checking':
        return '正在检查更新…';
      case 'upToDate':
        return '已是最新版本';
      case 'available':
        return `发现新版本 v${state.update.version}`;
      case 'downloading':
        return `正在下载 Charkle v${state.update.version}`;
      case 'verifying':
        return '正在校验安装包完整性…';
      case 'readyToInstall':
        return `Charkle v${state.update.version} 已准备就绪`;
      case 'installing':
        return '正在启动安装程序…';
      case 'manualInstallRequired':
        return '请手动运行更新安装程序';
      case 'failed':
        return '更新检查或下载失败';
      default:
        return '软件更新';
    }
  })();

  const publishedDate = formatPublishedDate(activeUpdate?.publishedAt);
  const canDismiss = state.status !== 'installing';

  const handleMarkdownClick = (e: React.MouseEvent<HTMLDivElement>) => {
    const anchor = (e.target as HTMLElement | null)?.closest('a');
    if (!anchor) return;
    const href = anchor.getAttribute('href');
    if (!href) return;
    e.preventDefault();
    if (/^https?:\/\//i.test(href)) {
      void getTransport().openExternalUrl(href);
    }
  };

  const renderFooter = () => {
    switch (state.status) {
      case 'checking':
        return (
          <div className="w-full flex items-center justify-end gap-2">
            <Button variant="standard" onClick={closeSheet}>
              隐藏
            </Button>
          </div>
        );

      case 'upToDate':
      case 'idle':
        return (
          <div className="w-full flex items-center justify-between gap-2">
            <Button variant="subtle" size="sm" onClick={() => void openReleasePage()}>
              <Open16Regular className="w-3.5 h-3.5" />
              GitHub Releases
            </Button>
            <div className="flex items-center gap-2">
              <Button
                variant="standard"
                onClick={() => void checkForUpdatesManually({ presentSheet: true })}
              >
                <ArrowClockwise16Regular className="w-3.5 h-3.5" />
                重新检查
              </Button>
              <Button variant="accent" onClick={closeSheet}>
                完成
              </Button>
            </div>
          </div>
        );

      case 'available':
        return (
          <div className="w-full flex items-center justify-between gap-2">
            <div className="flex items-center gap-1.5">
              <Button variant="subtle" size="sm" onClick={() => void skipCurrentUpdate()}>
                跳过此版本
              </Button>
              <Button variant="subtle" size="sm" onClick={() => void openReleasePage()}>
                <Open16Regular className="w-3.5 h-3.5" />
                Release 页面
              </Button>
            </div>
            <div className="flex items-center gap-2">
              <Button variant="standard" onClick={closeSheet}>
                稍后
              </Button>
              <Button variant="accent" onClick={() => void startDownload()}>
                <ArrowDownload16Regular className="w-4 h-4" />
                下载更新
              </Button>
            </div>
          </div>
        );

      case 'downloading':
        return (
          <div className="w-full flex items-center justify-between gap-2">
            <Button variant="subtle" size="sm" onClick={() => void openReleasePage()}>
              <Open16Regular className="w-3.5 h-3.5" />
              Release 页面
            </Button>
            <div className="flex items-center gap-2">
              <Button variant="standard" onClick={() => void cancelDownload()}>
                取消下载
              </Button>
              <Button variant="subtle" onClick={closeSheet}>
                后台下载
              </Button>
            </div>
          </div>
        );

      case 'verifying':
        return (
          <div className="w-full flex items-center justify-end gap-2">
            <Button variant="standard" onClick={closeSheet}>
              后台校验
            </Button>
          </div>
        );

      case 'readyToInstall':
        return (
          <div className="w-full flex items-center justify-between gap-2">
            <Button variant="subtle" size="sm" onClick={() => void revealDownloadedInstaller()}>
              <FolderOpen16Regular className="w-3.5 h-3.5" />
              在资源管理器中显示
            </Button>
            <div className="flex items-center gap-2">
              <Button variant="standard" onClick={closeSheet}>
                稍后安装
              </Button>
              <Button variant="accent" onClick={() => void installAndRelaunch()}>
                安装并重启
              </Button>
            </div>
          </div>
        );

      case 'installing':
        return (
          <div className="w-full flex items-center justify-end gap-2">
            <span className="text-[12px] text-[var(--text-secondary)]">
              正在交接给 Charkle 安装程序…
            </span>
          </div>
        );

      case 'manualInstallRequired':
        return (
          <div className="w-full flex items-center justify-between gap-2">
            <Button variant="subtle" size="sm" onClick={() => void revealDownloadedInstaller()}>
              <FolderOpen16Regular className="w-3.5 h-3.5" />
              在资源管理器中显示
            </Button>
            <div className="flex items-center gap-2">
              <Button variant="standard" onClick={closeSheet}>
                关闭
              </Button>
              <Button variant="accent" onClick={() => void openDownloadedInstaller()}>
                手动打开安装程序
              </Button>
            </div>
          </div>
        );

      case 'failed':
        return (
          <div className="w-full flex items-center justify-between gap-2">
            <Button variant="subtle" size="sm" onClick={() => void openReleasePage()}>
              <Open16Regular className="w-3.5 h-3.5" />
              前往 GitHub Releases
            </Button>
            <div className="flex items-center gap-2">
              <Button variant="standard" onClick={closeSheet}>
                关闭
              </Button>
              <Button
                variant="accent"
                onClick={() =>
                  state.update
                    ? void startDownload()
                    : void checkForUpdatesManually({ presentSheet: true })
                }
              >
                <ArrowClockwise16Regular className="w-3.5 h-3.5" />
                重试
              </Button>
            </div>
          </div>
        );
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={() => {
        if (canDismiss) closeSheet();
      }}
      closeOnBackdrop={canDismiss}
      hideCloseButton={true}
      width="md"
      noPadding={true}
      ariaLabel="Charkle 软件更新"
      footer={renderFooter()}
    >
      <div data-testid="app-update-modal" className="flex flex-col">
        {/* Custom Header Banner */}
        <div className="flex items-start justify-between gap-3.5 px-5 pt-5 pb-4 border-b border-[var(--win-stroke-divider)]">
          <div className="flex items-center gap-3.5 min-w-0">
            <CharkleBrandMark size={42} />
            <div className="min-w-0 flex flex-col gap-1">
              <h2 className="text-[17px] leading-[22px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] truncate">
                {headerTitle}
              </h2>
              {activeUpdate ? (
                <div className="flex flex-wrap items-center gap-1.5 text-[11.5px] text-[var(--text-secondary)] charkle-tabular">
                  <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] font-medium charkle-mono">
                    v{currentVersion} → v{activeUpdate.version}
                  </span>
                  {activeUpdate.assetSizeBytes > 0 && (
                    <span>· {formatByteCount(activeUpdate.assetSizeBytes)}</span>
                  )}
                  {publishedDate && <span>· {publishedDate}</span>}
                </div>
              ) : (
                <p className="text-[12px] text-[var(--text-secondary)] charkle-tabular">
                  当前版本：Charkle v{currentVersion}（Windows x64）
                </p>
              )}
            </div>
          </div>
          {canDismiss && (
            <button
              type="button"
              aria-label="关闭"
              onClick={closeSheet}
              className="charkle-pressable h-8 w-8 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer shrink-0"
            >
              <Dismiss16Regular className="w-4 h-4" />
            </button>
          )}
        </div>

        {/* Body Content */}
        <div className="px-5 py-4 flex flex-col gap-3.5">
          {/* Checking State */}
          {state.status === 'checking' && (
            <div className="py-6 flex flex-col items-center justify-center gap-2.5 text-center">
              <div className="w-6 h-6 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin motion-reduce:animate-none" />
              <div className="text-[13px] font-medium text-[var(--text-primary)]">
                正在连接 GitHub Releases 检查最新版本…
              </div>
              <div className="text-[12px] text-[var(--text-secondary)]">
                将自动匹配适用于 Windows x64 的签名安装包与 SHA-256 校验值
              </div>
            </div>
          )}

          {/* Up-To-Date State */}
          {state.status === 'upToDate' && (
            <div className="py-5 flex flex-col items-center justify-center gap-2 text-center">
              <CheckmarkCircle20Regular className="w-8 h-8 text-emerald-600 dark:text-emerald-400" />
              <div className="text-[14px] font-semibold text-[var(--text-primary)]">
                Charkle v{currentVersion} 已是最新正式版本
              </div>
              <div className="text-[12px] text-[var(--text-secondary)] charkle-tabular">
                检查时间：{formatRelativeCheckTime(state.checkedAtMs)}
              </div>
            </div>
          )}

          {/* Release Notes Card (when an update is available or in progress) */}
          {activeUpdate && (
            <div className="flex flex-col gap-1.5">
              <div className="flex items-center justify-between text-[12px]">
                <span className="font-medium text-[var(--text-secondary)]">更新说明</span>
                <span className="charkle-mono text-[11px] text-[var(--text-tertiary)] truncate max-w-[260px]">
                  {activeUpdate.assetName}
                </span>
              </div>
              <div
                onClick={handleMarkdownClick}
                className="max-h-[240px] overflow-y-auto charkle-scroll rounded-[8px] border border-[var(--win-stroke-divider)] bg-[var(--bg-subtle)]/65 px-3.5 py-3 text-[12.5px] leading-[1.65] text-[var(--text-primary)] [&_h1]:text-[14px] [&_h1]:font-semibold [&_h1]:mb-1.5 [&_h2]:text-[13px] [&_h2]:font-semibold [&_h2]:mt-2.5 [&_h2]:mb-1 [&_h3]:text-[12.5px] [&_h3]:font-semibold [&_h3]:mt-2 [&_h3]:mb-1 [&_ul]:list-disc [&_ul]:pl-5 [&_ul]:my-1 [&_ol]:list-decimal [&_ol]:pl-5 [&_ol]:my-1 [&_li]:my-0.5 [&_p]:my-1 [&_code]:charkle-mono [&_code]:text-[11px] [&_code]:px-1 [&_code]:py-0.5 [&_code]:rounded [&_code]:bg-[var(--win-subtle-hover)] [&_a]:text-[var(--accent)] [&_a]:underline"
              >
                {renderedNotesHtml ? (
                  <div dangerouslySetInnerHTML={{ __html: renderedNotesHtml }} />
                ) : (
                  <p className="text-[var(--text-secondary)]">
                    本次更新包含功能优化与稳定性改进，可点击下方按钮下载更新或前往 GitHub Release 查看完整变更。
                  </p>
                )}
              </div>
            </div>
          )}

          {/* Downloading Progress Strip */}
          {state.status === 'downloading' && (
            <div className="rounded-[8px] border border-[var(--win-stroke-divider)] bg-[var(--bg-subtle)]/75 px-3.5 py-3 flex flex-col gap-2">
              <div className="flex items-center justify-between text-[12px] charkle-tabular">
                <span className="font-medium text-[var(--text-primary)]">
                  正在通过 HTTPS 下载安装包…
                </span>
                <span className="text-[var(--text-secondary)]">
                  {Math.round(Math.max(0, Math.min(1, state.progress.fraction)) * 100)}% ·{' '}
                  {formatByteCount(state.progress.downloadedBytes)} /{' '}
                  {formatByteCount(state.progress.totalBytes || state.update.assetSizeBytes)}
                </span>
              </div>
              <div className="h-1.5 w-full rounded-full bg-[var(--win-subtle-hover)] overflow-hidden">
                <div
                  style={{
                    transform: `scaleX(${Math.max(0.03, Math.min(1, state.progress.fraction))})`,
                  }}
                  className="h-full w-full origin-left rounded-full bg-[var(--accent)] transition-transform duration-150 motion-reduce:transition-none"
                />
              </div>
            </div>
          )}

          {/* Verifying Strip */}
          {state.status === 'verifying' && (
            <div className="rounded-[8px] border border-[var(--win-stroke-divider)] bg-[var(--bg-subtle)]/75 px-3.5 py-3 flex items-center gap-2.5 text-[12.5px] text-[var(--text-primary)]">
              <div className="w-4 h-4 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin motion-reduce:animate-none shrink-0" />
              <span>正在校验 SHA-256 摘要与 Windows PE 可执行文件头…</span>
            </div>
          )}

          {/* Ready To Install Strip */}
          {state.status === 'readyToInstall' && (
            <div className="rounded-[8px] border border-emerald-500/30 bg-emerald-500/8 px-3.5 py-3 flex flex-col gap-1.5">
              <div className="flex items-center gap-2 text-[12.5px] font-medium text-emerald-700 dark:text-emerald-300">
                <ShieldCheckmark16Regular className="w-4 h-4 shrink-0" />
                <span>
                  {state.installer.checksumVerifiedAgainstRelease
                    ? 'SHA-256 校验已通过，安装包完整可信'
                    : '安装包下载与 Windows PE 结构校验已通过'}
                </span>
              </div>
              <div className="text-[11.5px] text-[var(--text-secondary)] flex flex-wrap items-center gap-x-2 gap-y-0.5">
                <span className="charkle-mono">
                  SHA-256: {shortSha256(state.installer.verifiedSha256)}
                </span>
                <span>·</span>
                <span>点击「安装并重启」将保留素材库与配置并自动重启</span>
              </div>
            </div>
          )}

          {/* Installing Strip */}
          {state.status === 'installing' && (
            <div className="rounded-[8px] border border-[var(--win-stroke-divider)] bg-[var(--bg-subtle)]/75 px-3.5 py-3 flex items-center gap-2.5 text-[12.5px] text-[var(--text-primary)]">
              <div className="w-4 h-4 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin motion-reduce:animate-none shrink-0" />
              <span>正在退出当前实例并启动 NSIS 增量升级，升级完成后将自动重新打开 Charkle…</span>
            </div>
          )}

          {/* Manual Install Fallback Strip */}
          {state.status === 'manualInstallRequired' && (
            <div className="rounded-[8px] border border-amber-500/35 bg-amber-500/10 px-3.5 py-3 flex items-start gap-2.5">
              <Warning20Regular className="w-5 h-5 text-amber-600 dark:text-amber-400 shrink-0 mt-0.5" />
              <div className="min-w-0 flex flex-col gap-1">
                <div className="text-[12.5px] font-medium text-[var(--text-primary)]">
                  自动启动升级受阻，可手动运行已校验的安装包
                </div>
                <div className="text-[12px] text-[var(--text-secondary)]">{state.reason}</div>
              </div>
            </div>
          )}

          {/* Failed Strip */}
          {state.status === 'failed' && (
            <div className="rounded-[8px] border border-red-500/30 bg-red-500/8 px-3.5 py-3 flex items-start gap-2.5">
              <ErrorCircle20Regular className="w-5 h-5 text-red-600 dark:text-red-400 shrink-0 mt-0.5" />
              <div className="min-w-0 flex flex-col gap-1">
                <div className="text-[12.5px] font-medium text-[var(--text-primary)]">
                  无法完成更新操作
                </div>
                <div className="text-[12px] text-[var(--text-secondary)] break-words">
                  {state.message}
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
    </ModalShell>
  );
};
