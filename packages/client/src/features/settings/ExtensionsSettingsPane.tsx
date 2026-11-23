import React, { useEffect, useRef, useState } from 'react';
import {
  Bookmark,
  Check,
  Copy,
  Download,
  Globe,
  GripHorizontal,
  KeyRound,
  X,
} from 'lucide-react';
import { apiClient } from '../../api/client';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import {
  InlineGuideDisclosure,
  SettingsButton,
  SettingsCardDivider,
  SettingsGuideStep,
  SettingsRow,
  SettingsSection,
} from './SettingsChrome';

function buildBookmarkletCode(origin: string): string {
  const cleanOrigin = origin.replace(/\/+$/, '');
  return `javascript:(()=>{var u=encodeURIComponent(location.href),t=encodeURIComponent(document.title||''),s=encodeURIComponent((window.getSelection?String(window.getSelection()):'').trim().slice(0,1500));window.open('${cleanOrigin}/?clip_url='+u+'&clip_title='+t+(s?'&clip_text='+s:''),'_blank','noopener');})();`;
}

export const ExtensionsSettingsPane: React.FC = () => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const origin =
    typeof window !== 'undefined' ? window.location.origin : 'http://localhost:3188';
  const bookmarkletCode = buildBookmarkletCode(origin);
  const bookmarkletAnchorRef = useRef<HTMLAnchorElement | null>(null);

  const [downloadingExt, setDownloadingExt] = useState(false);
  const [downloadingFigma, setDownloadingFigma] = useState(false);
  const [copiedOrigin, setCopiedOrigin] = useState(false);
  const [creatingToken, setCreatingToken] = useState(false);
  const [generatedToken, setGeneratedToken] = useState<string | null>(null);
  const [copiedToken, setCopiedToken] = useState(false);
  const [copiedBookmarklet, setCopiedBookmarklet] = useState(false);

  // Set javascript: href imperatively so React stays warning-free while native drag-to-bar works
  useEffect(() => {
    const anchor = bookmarkletAnchorRef.current;
    if (anchor) {
      anchor.setAttribute('href', bookmarkletCode);
    }
  }, [bookmarkletCode]);

  const downloadZip = async (
    url: string,
    filename: string,
    successMsg: string,
    setBusy: (busy: boolean) => void,
  ) => {
    setBusy(true);
    try {
      const res = await fetch(url, { credentials: 'include' });
      if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw new Error(text || `下载失败 (${res.status})`);
      }
      const blob = await res.blob();
      const objectURL = URL.createObjectURL(blob);
      const link = window.document.createElement('a');
      link.href = objectURL;
      link.download = filename;
      window.document.body.appendChild(link);
      link.click();
      link.remove();
      window.setTimeout(() => URL.revokeObjectURL(objectURL), 1000);
      pushToast({ tone: 'success', message: successMsg });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '下载压缩包失败',
      });
    } finally {
      setBusy(false);
    }
  };

  const handleCopyOrigin = async () => {
    try {
      await navigator.clipboard.writeText(origin);
      setCopiedOrigin(true);
      pushToast({ tone: 'success', message: `已复制服务地址 ${origin}` });
      window.setTimeout(() => setCopiedOrigin(false), 1800);
    } catch {
      pushToast({ tone: 'error', message: '复制服务地址失败，请手动复制' });
    }
  };

  const handleCreateExtensionToken = async () => {
    setCreatingToken(true);
    try {
      const res = await apiClient.createApiToken({
        name: 'Charkle 浏览器扩展',
        scopes: ['read', 'write'],
      });
      setGeneratedToken(res.token);
      setCopiedToken(false);
      pushToast({ tone: 'success', message: '已生成扩展专用访问令牌（请立即复制保存）' });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '生成扩展令牌失败',
      });
    } finally {
      setCreatingToken(false);
    }
  };

  const handleCopyToken = async () => {
    if (!generatedToken) return;
    try {
      await navigator.clipboard.writeText(generatedToken);
      setCopiedToken(true);
      pushToast({ tone: 'success', message: '已复制扩展专用令牌' });
      window.setTimeout(() => setCopiedToken(false), 1800);
    } catch {
      pushToast({ tone: 'error', message: '复制令牌失败' });
    }
  };

  const handleCopyBookmarklet = async () => {
    try {
      await navigator.clipboard.writeText(bookmarkletCode);
      setCopiedBookmarklet(true);
      pushToast({
        tone: 'success',
        message: '已复制书签代码，可在浏览器新建书签并将代码粘贴为网址',
      });
      window.setTimeout(() => setCopiedBookmarklet(false), 1800);
    } catch {
      pushToast({ tone: 'error', message: '复制书签代码失败' });
    }
  };

  return (
    <div className="flex flex-col gap-[22px]">
      {/* 1. 浏览器采集扩展 */}
      <SettingsSection title="浏览器采集扩展">
        <SettingsRow
          title="Charkle 浏览器采集扩展"
          subtitle="Chrome / Edge / Arc / Brave · 右键收藏图片与链接、批量抓图、网页截屏与取色器"
        >
          <SettingsButton
            variant="primary"
            loading={downloadingExt}
            onClick={() =>
              void downloadZip(
                apiClient.extensionDownloadURL(),
                'charkle-web-clipper-extension.zip',
                '已开始下载 Charkle 浏览器扩展 (.zip)',
                setDownloadingExt,
              )
            }
          >
            <Download size={12} />
            下载扩展 (.zip)
          </SettingsButton>
        </SettingsRow>

        <div className="px-4 pb-3 flex flex-col gap-2.5">
          <div className="flex flex-wrap items-center gap-2">
            <SettingsButton variant="secondary" onClick={() => void handleCopyOrigin()}>
              {copiedOrigin ? (
                <Check size={12} className="text-[var(--settings-positive,var(--success))]" />
              ) : (
                <Copy size={12} />
              )}
              {copiedOrigin ? '已复制服务地址' : '复制当前服务地址'}
            </SettingsButton>
            <SettingsButton
              variant="secondary"
              loading={creatingToken}
              onClick={() => void handleCreateExtensionToken()}
            >
              <KeyRound size={12} />
              生成扩展令牌
            </SettingsButton>
            <span className="inline-flex items-center gap-1.5 text-[11px] text-[var(--text-tertiary)] font-mono truncate">
              <Globe size={11} className="shrink-0" />
              {origin}
            </span>
          </div>

          {generatedToken && (
            <div className="p-3 rounded-[9px] bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--accent-ring)] flex flex-col gap-2">
              <div className="flex items-center justify-between gap-2">
                <span className="text-[11.5px] font-semibold text-[var(--text-primary)] inline-flex items-center gap-1.5">
                  <KeyRound size={12} className="text-[var(--accent)]" />
                  扩展专用访问令牌（仅显示这一次）
                </span>
                <button
                  type="button"
                  aria-label="隐藏令牌"
                  onClick={() => setGeneratedToken(null)}
                  className="charkle-pressable w-6 h-6 rounded-[6px] inline-flex items-center justify-center text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer"
                >
                  <X size={12} />
                </button>
              </div>
              <div className="flex items-center gap-2">
                <code className="flex-1 min-w-0 px-2.5 py-1.5 rounded-[7px] bg-[var(--settings-card,var(--bg-elevated))] border border-[var(--settings-border,var(--border-hairline))] font-mono text-[11px] text-[var(--text-primary)] select-all break-all">
                  {generatedToken}
                </code>
                <SettingsButton variant="primary" onClick={() => void handleCopyToken()}>
                  {copiedToken ? <Check size={12} /> : <Copy size={12} />}
                  {copiedToken ? '已复制' : '复制'}
                </SettingsButton>
              </div>
              <div className="text-[10.5px] text-[var(--text-tertiary)]">
                权限：读写素材库 · 如需吊销请前往「账号与安全」。
              </div>
            </div>
          )}
        </div>

        <InlineGuideDisclosure title="如何安装并连接浏览器扩展（3 步）">
          <SettingsGuideStep
            number={1}
            title="下载并解压扩展压缩包"
            detail="点击上方「下载扩展 (.zip)」并解压到一个长期保留的本地文件夹。"
          />
          <SettingsGuideStep
            number={2}
            title="在浏览器加载已解压的扩展程序"
            detail="打开 chrome://extensions，开启右上角「开发者模式」，点击「加载已解压的扩展程序」并选择刚解压的文件夹。"
          />
          <SettingsGuideStep
            number={3}
            title="填入服务地址与扩展令牌"
            detail="打开扩展设置页，粘贴当前服务地址与上方生成的 chk_... 令牌，点击「测试并保存」即可开始跨网页收藏。"
          />
        </InlineGuideDisclosure>

        <SettingsCardDivider />

        <SettingsRow
          title="Safari / 移动端书签小工具"
          subtitle="免安装：将按钮拖至书签栏，在任意网页点击即可收藏当前链接与选中文本"
        >
          <a
            ref={bookmarkletAnchorRef}
            draggable
            onClick={(e) => {
              e.preventDefault();
              pushToast({
                tone: 'info',
                message: '请将「收藏到 Charkle」按住拖到浏览器书签栏，或点击右侧复制书签代码',
              });
            }}
            title="按住拖到浏览器书签栏"
            className="charkle-pressable inline-flex items-center gap-1.5 h-[30px] px-3 rounded-full bg-[var(--settings-subtle,var(--bg-subtle))] border border-[var(--settings-border,var(--border-hairline))] text-[12px] font-medium text-[var(--text-primary)] hover:border-[var(--accent)] cursor-grab active:cursor-grabbing select-none transition-colors duration-[var(--duration-press,120ms)] ease-[var(--ease-out)]"
          >
            <GripHorizontal size={12} className="text-[var(--text-tertiary)]" />
            <Bookmark size={12} className="text-[var(--accent)]" />
            收藏到 Charkle
          </a>
          <SettingsButton variant="secondary" onClick={() => void handleCopyBookmarklet()}>
            {copiedBookmarklet ? (
              <Check size={12} className="text-[var(--settings-positive,var(--success))]" />
            ) : (
              <Copy size={12} />
            )}
            {copiedBookmarklet ? '已复制' : '复制书签代码'}
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>

      {/* 2. Figma 与 FigJam */}
      <SettingsSection title="Figma 与 FigJam">
        <SettingsRow
          title="Charkle → Figma / FigJam 插件"
          subtitle="纯本地离线导入，无需 API 密钥，保留独立图层、原图像素与动图"
        >
          <SettingsButton
            variant="primary"
            loading={downloadingFigma}
            onClick={() =>
              void downloadZip(
                apiClient.figmaPluginDownloadURL(),
                'charkle-figma-bridge-plugin.zip',
                '已开始下载 Figma 导入插件 (.zip)',
                setDownloadingFigma,
              )
            }
          >
            <Download size={12} />
            下载 Figma 插件 (.zip)
          </SettingsButton>
        </SettingsRow>

        <InlineGuideDisclosure title="如何在 Figma 桌面端导入（仅首次需要，3 步）">
          <SettingsGuideStep
            number={1}
            title="下载并解压插件包"
            detail="点击上方「下载 Figma 插件 (.zip)」并解压到一个不会被随意删除的本地文件夹。"
          />
          <SettingsGuideStep
            number={2}
            title="打开 Figma 开发者导入入口"
            detail="在 Figma 桌面端菜单栏依次点击 Plugins → Development → Import plugin from manifest…"
          />
          <SettingsGuideStep
            number={3}
            title="选中 manifest.json 完成安装"
            detail="选择解压目录里的 manifest.json，此后即可在 Figma 设计文件与 FigJam 白板中随时启动插件。"
          />
        </InlineGuideDisclosure>

        <InlineGuideDisclosure title="查看情绪板导入 Figma / FigJam 完整流程">
          <SettingsGuideStep
            number={1}
            title="从情绪板导出 .charkleboard 文件"
            detail="打开任意情绪板 → 点击右上角「导出」→ 切换到「Figma / FigJam (.charkleboard)」下载迁移包。"
          />
          <SettingsGuideStep
            number={2}
            title="在画布中运行 Charkle Board Importer"
            detail="打开目标 Figma 或 FigJam 文档，通过插件菜单启动 Charkle Board Importer。"
          />
          <SettingsGuideStep
            number={3}
            title="拖入迁移包，1:1 还原全部元素"
            detail="将 .charkleboard 文件拖入插件窗口，自动生成独立图片图层、动态 GIF、便签、分组框、箭头连线与手绘标注。"
          />
        </InlineGuideDisclosure>
      </SettingsSection>
    </div>
  );
};
