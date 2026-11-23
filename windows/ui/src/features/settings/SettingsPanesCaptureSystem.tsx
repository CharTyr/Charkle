import React, { useEffect, useState } from 'react';
import {
  Camera,
  CheckCircle2,
  Clipboard,
  Copy,
  Download,
  Keyboard,
  PanelTop,
  Pin,
  RotateCcw,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import { Button, SegmentedControl } from '../../design-system';
import { useCoordinatorStore, useSyncAIStore } from '../../stores';
import type { DesktopIntegrationStatus, HotkeyConfig } from '../../types/domain';

export const DropShelfSettingsPane: React.FC = () => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const [defaultTarget, setDefaultTarget] = useState<'inbox' | 'activeMoodboard'>('inbox');
  const [pinned, setPinned] = useState(false);

  return (
    <div data-testid="settings-pane-dropShelf" className="flex flex-col gap-4">
      <div>
        <h2 className="text-[16px] font-semibold text-[var(--text-primary)]">顶部悬浮窗</h2>
        <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
          Windows 端独立置顶的灵感收集胶囊（对应 macOS 刘海浮窗），拖拽任意文件或图片至屏幕顶部中央即可无焦点自动弹出。
        </p>
      </div>

      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-3.5">
        <div className="flex items-center justify-between gap-3">
          <div>
            <div className="text-[13px] font-medium text-[var(--text-primary)]">默认投递目标</div>
            <div className="text-[11.5px] text-[var(--text-tertiary)]">
              拖入悬浮窗或一键剪贴板采集时的默认落点
            </div>
          </div>
          <SegmentedControl<'inbox' | 'activeMoodboard'>
            value={defaultTarget}
            onChange={setDefaultTarget}
            ariaLabel="悬浮窗默认投递目标"
            options={[
              { value: 'inbox', label: '收件箱' },
              { value: 'activeMoodboard', label: '当前活跃情绪板' },
            ]}
          />
        </div>

        <div className="h-px bg-[var(--border-hairline)]" />

        <div className="flex items-center justify-between gap-2">
          <div>
            <div className="text-[13px] font-medium text-[var(--text-primary)]">即时预览与固定</div>
            <div className="text-[11.5px] text-[var(--text-tertiary)]">
              支持紧凑胶囊与展开全瀑布流抽屉模式，卡片可直接原生拖出至 Figma / Photoshop / Explorer
            </div>
          </div>
          <div className="flex items-center gap-2 shrink-0">
            <Button
              variant="secondary"
              size="xs"
              onClick={async () => {
                const next = await getTransport().setShelfPinned(!pinned);
                setPinned(next);
                pushToast({
                  message: next ? '已固定顶部悬浮窗' : '已取消固定顶部悬浮窗',
                  tone: 'info',
                });
              }}
            >
              <Pin size={12.5} />
              {pinned ? '取消固定' : '固定显示'}
            </Button>
            <Button
              variant="primary"
              size="xs"
              onClick={() => void getTransport().toggleShelf()}
            >
              <PanelTop size={12.5} />
              呼出 / 预览悬浮窗
            </Button>
          </div>
        </div>
      </section>
    </div>
  );
};

export const CaptureShortcutsSettingsPane: React.FC = () => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const [status, setStatus] = useState<DesktopIntegrationStatus | null>(null);
  const [hotkeys, setHotkeys] = useState<HotkeyConfig>({
    captureArea: 'Alt+Shift+A',
    toggleShelf: 'Alt+Shift+S',
    collectClipboard: 'Alt+Shift+V',
    enabled: true,
  });

  useEffect(() => {
    void getTransport()
      .getDesktopIntegrationStatus()
      .then((st) => {
        setStatus(st);
        setHotkeys(st.hotkeys);
      })
      .catch(() => {});
  }, []);

  const saveHotkeys = async () => {
    const saved = await getTransport().updateHotkeys(hotkeys);
    setHotkeys(saved);
    pushToast({ message: '全局快捷键已保存并立即生效', tone: 'success' });
  };

  return (
    <div data-testid="settings-pane-captureShortcuts" className="flex flex-col gap-4">
      <div>
        <h2 className="text-[16px] font-semibold text-[var(--text-primary)]">采集与快捷键</h2>
        <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
          配置系统级区域截图、悬浮窗呼出、剪贴板采集热键，以及应用内高效整理快捷键一览。
        </p>
      </div>

      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-3">
        <label className="flex items-center justify-between cursor-pointer">
          <span className="text-[13px] font-medium text-[var(--text-primary)]">
            启用 Windows 全局系统热键
          </span>
          <input
            type="checkbox"
            checked={hotkeys.enabled}
            onChange={(e) => setHotkeys({ ...hotkeys, enabled: e.target.checked })}
            className="h-4 w-4 accent-[var(--accent)]"
          />
        </label>

        <div className="grid grid-cols-1 sm:grid-cols-3 gap-2.5">
          <label className="flex flex-col gap-1 text-[11.5px]">
            <span className="text-[var(--text-secondary)] inline-flex items-center gap-1">
              <Camera size={12} />
              区域截图
            </span>
            <input
              type="text"
              value={hotkeys.captureArea}
              onChange={(e) => setHotkeys({ ...hotkeys, captureArea: e.target.value })}
              className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] font-mono text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
            />
          </label>
          <label className="flex flex-col gap-1 text-[11.5px]">
            <span className="text-[var(--text-secondary)] inline-flex items-center gap-1">
              <PanelTop size={12} />
              呼出悬浮窗
            </span>
            <input
              type="text"
              value={hotkeys.toggleShelf}
              onChange={(e) => setHotkeys({ ...hotkeys, toggleShelf: e.target.value })}
              className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] font-mono text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
            />
          </label>
          <label className="flex flex-col gap-1 text-[11.5px]">
            <span className="text-[var(--text-secondary)] inline-flex items-center gap-1">
              <Clipboard size={12} />
              采集剪贴板
            </span>
            <input
              type="text"
              value={hotkeys.collectClipboard}
              onChange={(e) => setHotkeys({ ...hotkeys, collectClipboard: e.target.value })}
              className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] font-mono text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
            />
          </label>
        </div>

        <div className="flex items-center justify-between pt-1">
          <span className="text-[11px] text-[var(--text-tertiary)]">
            协议呼出：{status?.deepLinkScheme ?? 'charkle://'}（asset / folder / board / capture）
          </span>
          <Button variant="primary" size="xs" onClick={() => void saveHotkeys()}>
            保存热键配置
          </Button>
        </div>
      </section>

      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4">
        <div className="text-[12.5px] font-semibold text-[var(--text-primary)] mb-2.5 inline-flex items-center gap-1.5">
          <Keyboard size={14} />
          应用内常用快捷键
        </div>
        <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-[12px]">
          {[
            ['Ctrl + J', '极速跳转任意素材 / 文件夹 / 情绪板'],
            ['Space', '打开 / 关闭高清快速预览'],
            ['Ctrl + 1 / 2 / 3', '切换瀑布流 / 等高行 / 胶片带'],
            ['1 – 9（收件箱）', '一键快速归档到前 9 个文件夹'],
            ['Ctrl + ,', '打开设置中心'],
            ['Ctrl + Z / Y', '情绪板画布撤销与重做'],
          ].map(([k, desc]) => (
            <div key={k} className="flex items-center justify-between gap-2 py-0.5">
              <span className="text-[var(--text-secondary)] truncate">{desc}</span>
              <kbd className="px-1.5 py-0.5 rounded bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[11px] font-mono text-[var(--text-primary)] shrink-0">
                {k}
              </kbd>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
};

export const ExtensionsSettingsPane: React.FC = () => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const [exportedPath, setExportedPath] = useState<string | null>(null);

  const handleExportPlugin = async () => {
    const dir = await getTransport().pickDirectoryDialog('选择导出 Figma 插件文件夹的位置');
    if (!dir) return;
    try {
      const dest = await getTransport().exportFigmaPluginBundle(dir);
      setExportedPath(dest);
      pushToast({ message: `已导出 Figma 插件目录至 ${dest}`, tone: 'success' });
    } catch (err) {
      pushToast({
        message: `导出插件失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    }
  };

  return (
    <div data-testid="settings-pane-extensions" className="flex flex-col gap-4">
      <div>
        <h2 className="text-[16px] font-semibold text-[var(--text-primary)]">插件与扩展</h2>
        <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
          将情绪板离线无损导入 Figma Design / FigJam，以及通过浏览器与深链接快速采集网页灵感。
        </p>
      </div>

      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-3">
        <div className="flex items-start justify-between gap-3">
          <div>
            <div className="text-[13.5px] font-semibold text-[var(--text-primary)]">
              Charkle Figma / FigJam 离线无损桥接插件
            </div>
            <p className="text-[12px] text-[var(--text-secondary)] mt-1 leading-relaxed">
              配合情绪板导出的 `.charkleboard` 文件，支持 &gt;4096px 原图无损分块还原、便签、分组框、色卡条、FigJam 原生连线、矢量手绘与动画 GIF。
            </p>
          </div>
          <Button variant="primary" size="sm" onClick={() => void handleExportPlugin()}>
            <Download size={13.5} />
            导出插件包
          </Button>
        </div>

        <ol className="list-decimal list-inside text-[12px] text-[var(--text-secondary)] space-y-1 bg-[var(--bg-subtle)]/60 rounded-[var(--radius-settings-inner)] p-3">
          <li>点击「导出插件包」，将 `Charkle-Figma-Plugin` 文件夹保存到本机任意位置。</li>
          <li>在 Figma Desktop 中依次打开 Plugins → Development → Import plugin from manifest…。</li>
          <li>选择导出的 `manifest.json`，即可直接拖入 `.charkleboard` 文件一键导入。</li>
        </ol>

        {exportedPath && (
          <div className="text-[11.5px] text-[var(--accent)] flex items-center gap-1.5">
            <CheckCircle2 size={14} />
            已导出至：{exportedPath}
          </div>
        )}
      </section>

      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-2">
        <div className="text-[13px] font-semibold text-[var(--text-primary)]">
          浏览器与系统深度集成采集
        </div>
        <p className="text-[12px] text-[var(--text-secondary)] leading-relaxed">
          在 Chrome / Edge 中直接复制图片、网址（自动解析 X / Threads / Bluesky / GitHub 仓库与卡片）或颜色值，按{' '}
          <kbd className="px-1 py-0.5 rounded bg-[var(--bg-subtle)] text-[11px] font-mono">
            Alt+Shift+V
          </kbd>{' '}
          即可零打断采集；也可直接从浏览器将图片拖向屏幕顶部中央呼出悬浮窗。
        </p>
      </section>
    </div>
  );
};

export const AdvancedAboutSettingsPane: React.FC = () => {
  const diagnostics = useSyncAIStore((s) => s.diagnostics);
  const surfaceState = useCoordinatorStore((s) => s.surfaceState);
  const closeSettings = useCoordinatorStore((s) => s.closeSettings);
  const setOnboardingOpen = useCoordinatorStore((s) => s.setOnboardingOpen);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const copyDiagnostics = async () => {
    const payload = JSON.stringify(
      {
        appVersion: diagnostics?.appVersion ?? '1.0.1',
        schemaVersion: diagnostics?.schemaVersion ?? 2,
        platform: 'Windows x64 (Tauri v2 + Rust)',
        surface: surfaceState,
        ocr: diagnostics?.ocr,
        gdirect: diagnostics?.gdirect,
      },
      null,
      2,
    );
    await navigator.clipboard?.writeText(payload).catch(() => {});
    pushToast({ message: '已复制系统诊断快照到剪贴板', tone: 'success' });
  };

  return (
    <div data-testid="settings-pane-advancedAbout" className="flex flex-col gap-4">
      <div>
        <h2 className="text-[16px] font-semibold text-[var(--text-primary)]">高级与关于</h2>
        <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
          查看版本、跨平台数据库 Schema、诊断信息及重新进入新手引导工作室。
        </p>
      </div>

      <section className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-4 flex flex-col gap-2.5 text-[12.5px]">
        <div className="flex items-center justify-between">
          <span className="text-[var(--text-secondary)]">Charkle Windows 版本</span>
          <span className="font-semibold text-[var(--text-primary)] charkle-tabular">
            v{diagnostics?.appVersion ?? '1.0.1'}
          </span>
        </div>
        <div className="flex items-center justify-between">
          <span className="text-[var(--text-secondary)]">跨平台数据库 Schema</span>
          <span className="font-mono text-[var(--text-primary)]">
            v{diagnostics?.schemaVersion ?? 2}（与 macOS v1.0.1 双向兼容）
          </span>
        </div>
        <div className="flex items-center justify-between gap-4">
          <span className="text-[var(--text-secondary)] shrink-0">数据库文件</span>
          <span className="font-mono text-[11.5px] text-[var(--text-tertiary)] truncate">
            {diagnostics?.databasePath ?? '%LOCALAPPDATA%\\Charkle\\Library.sqlite3'}
          </span>
        </div>

        <div className="pt-2.5 mt-1 border-t border-[var(--border-hairline)] flex items-center justify-between gap-2">
          <Button variant="secondary" size="sm" onClick={() => void copyDiagnostics()}>
            <Copy size={13.5} />
            复制诊断快照
          </Button>
          <Button
            variant="secondary"
            size="sm"
            onClick={() => {
              closeSettings();
              setOnboardingOpen(true);
            }}
          >
            <RotateCcw size={13.5} />
            重新运行新手引导
          </Button>
        </div>
      </section>
    </div>
  );
};
