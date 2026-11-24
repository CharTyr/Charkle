import React, { useEffect, useState } from 'react';
import {
  Camera,
  Clipboard,
  Copy,
  Download,
  Eye,
  EyeOff,
  FolderOpen,
  HardDrive,
  PanelTop,
  Pin,
  RefreshCw,
  RotateCcw,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import { CharkleBrandMark, CustomSelect, SegmentedControl } from '../../design-system';
import { useCoordinatorStore, useLibraryStore, useSyncAIStore } from '../../stores';
import type {
  DriveSyncConfig,
  DriveTransportMode,
  ExtensionBridgeStateDto,
  HotkeyConfig,
  ShelfSettings,
} from '../../types/domain';
import {
  InlineGuideDisclosure,
  SettingsButton,
  SettingsCardDivider,
  SettingsGuideStep,
  SettingsInput,
  SettingsRow,
  SettingsSection,
  SettingsStatusBadge,
  SettingsSubModal,
  SettingsSwitch,
} from './SettingsChrome';
import { GoogleOAuthSetupModal } from './SettingsPanesFoundation';

const DEFAULT_HOTKEYS: HotkeyConfig = {
  enabled: true,
  captureArea: 'Alt+Shift+A',
  toggleShelf: 'Alt+Shift+S',
  collectClipboard: 'Alt+Shift+V',
};

const DEFAULT_SYNC_CONFIG: DriveSyncConfig = {
  mode: 'localOnly',
  rootFolderName: 'Charkle',
  sharedFolderURLOrID: '',
  mountPath: 'G:\\',
  selectedGDirectAccount: null,
  useGDirectIPAcceleration: true,
  webDAVServerURL: '',
  webDAVUsername: '',
  webDAVRemotePath: '/Charkle',
  localLibraryPath: '',
  autoSyncIntervalSeconds: 120,
  syncThumbnails: true,
  syncEmbeddings: true,
};

// =========================================================================
// Pane 4: 顶部悬浮窗 (DropShelfSettingsPane) — mirrors NotchShelfSettingsPane.swift 1:1
// =========================================================================

export const DropShelfSettingsPane: React.FC = () => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const folders = useLibraryStore((s) => s.folders);
  const [settings, setSettings] = useState<ShelfSettings>({
    enabled: true,
    hoverTriggerEnabled: true,
    defaultTargetMode: 'inbox',
    defaultFolderId: null,
    minimalMode: false,
  });
  const [pinned, setPinned] = useState(false);
  const [toggleShortcut, setToggleShortcut] = useState('Alt+Shift+S');
  const [enteringMinimal, setEnteringMinimal] = useState(false);

  useEffect(() => {
    void getTransport()
      .getShelfSettings()
      .then(setSettings)
      .catch(() => {});
    void getTransport()
      .getDesktopIntegrationStatus()
      .then((st) => {
        setPinned(st.shelfPinned);
        if (st.hotkeys.toggleShelf) setToggleShortcut(st.hotkeys.toggleShelf);
      })
      .catch(() => {});
  }, []);

  const persistSettings = async (patch: Partial<ShelfSettings>) => {
    const prev = settings;
    const next: ShelfSettings = { ...settings, ...patch };
    setSettings(next);
    try {
      const saved = await getTransport().saveShelfSettings(next);
      setSettings(saved);
    } catch (err) {
      setSettings(prev);
      pushToast({
        message: err instanceof Error ? err.message : '保存顶部悬浮窗配置失败',
        tone: 'error',
      });
    }
  };

  return (
    <div data-testid="settings-pane-dropShelf" className="flex flex-col gap-[22px]">
      <SettingsSection title="顶部灵感浮窗">
        <SettingsRow
          title="启用屏幕顶部灵感浮窗"
          subtitle="在其他应用中拖起图片、链接或文件时，屏幕顶部自动滑出收纳区"
        >
          <SettingsSwitch
            checked={settings.enabled}
            ariaLabel="启用屏幕顶部灵感浮窗"
            onChange={(enabled) => void persistSettings({ enabled })}
          />
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="悬停顶部中央自动展开"
          subtitle="鼠标移至屏幕顶部中央时轻滑唤出浮窗，快速查看最近素材或拖出使用"
          disabled={!settings.enabled}
        >
          <SettingsSwitch
            checked={settings.hoverTriggerEnabled}
            disabled={!settings.enabled}
            ariaLabel="鼠标悬停屏幕顶部中央自动唤出"
            onChange={(hoverTriggerEnabled) => void persistSettings({ hoverTriggerEnabled })}
          />
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="默认收纳目标"
          subtitle="拖入浮窗或通过快捷键采集的新灵感默认落入此位置（也可在浮窗顶部随时切换）"
          disabled={!settings.enabled}
        >
          <SegmentedControl<'inbox' | 'folder' | 'activeMoodboard'>
            value={settings.defaultTargetMode}
            onChange={(mode) =>
              void persistSettings({
                defaultTargetMode: mode,
                defaultFolderId:
                  mode === 'folder'
                    ? (settings.defaultFolderId ?? folders[0]?.id ?? null)
                    : settings.defaultFolderId,
              })
            }
            ariaLabel="悬浮窗默认投递目标"
            options={[
              { value: 'inbox', label: '收件箱' },
              { value: 'folder', label: '指定文件夹' },
              { value: 'activeMoodboard', label: '活跃情绪板' },
            ]}
          />
        </SettingsRow>

        {settings.defaultTargetMode === 'folder' && (
          <>
            <SettingsCardDivider />
            <SettingsRow
              title="指定默认文件夹"
              subtitle="新采集的素材将直接归入此目录"
              disabled={!settings.enabled}
            >
              <div className="w-[200px]">
                <CustomSelect
                  value={settings.defaultFolderId ?? ''}
                  onChange={(val) => void persistSettings({ defaultFolderId: val || null })}
                  ariaLabel="指定默认投递文件夹"
                  options={[
                    { value: '', label: '未选择（回落至收件箱）' },
                    ...folders.map((f) => ({ value: f.id, label: f.name })),
                  ]}
                />
              </div>
            </SettingsRow>
          </>
        )}

        <SettingsCardDivider />

        <SettingsRow
          title="预览顶部浮窗效果"
          subtitle={`立即在屏幕顶部展开浮窗，体验收纳与快速拖出交互（快捷键 ${toggleShortcut}）`}
          disabled={!settings.enabled}
        >
          <SettingsButton
            variant="secondary"
            disabled={!settings.enabled}
            onClick={async () => {
              try {
                const next = await getTransport().setShelfPinned(!pinned);
                setPinned(next);
                pushToast({
                  message: next ? '已固定顶部浮窗' : '已取消固定顶部浮窗',
                  tone: 'info',
                });
              } catch (err) {
                pushToast({
                  message: err instanceof Error ? err.message : '切换固定状态失败',
                  tone: 'error',
                });
              }
            }}
          >
            <Pin size={12.5} />
            {pinned ? '取消固定' : '固定展开'}
          </SettingsButton>
          <SettingsButton
            variant="primary"
            disabled={!settings.enabled}
            onClick={() =>
              void getTransport()
                .toggleShelf()
                .catch((err) => {
                  pushToast({
                    message: err instanceof Error ? err.message : '展开顶部浮窗失败',
                    tone: 'error',
                  });
                })
            }
          >
            <PanelTop size={12.5} />
            预览顶部浮窗
          </SettingsButton>
        </SettingsRow>

        <InlineGuideDisclosure title="跨应用拖图与「活跃情绪板」连采技巧">
          <SettingsGuideStep
            number="1"
            title="浏览器 / Figma / 文件资源管理器直接往屏幕顶部甩"
            detail="无需切换回 Charkle 窗口，拖起图片时顶部浮窗会自动滑出接住素材。"
          />
          <SettingsGuideStep
            number="2"
            title="锁定「当前活跃情绪板」，边逛网页边长出一块板"
            detail="在浮窗顶部切换目标为「活跃情绪板」，之后所有截图、剪贴板收藏和拖图都会自动同步追加进画布。"
          />
          <SettingsGuideStep
            number="3"
            title="反向拖出素材同样顺手"
            detail="悬停顶部唤出浮窗后，可将最近收藏或完整瀑布流中的参考图直接拖进 Figma、Photoshop 或设计软件。"
          />
        </InlineGuideDisclosure>
      </SettingsSection>

      <div data-testid="settings-minimal-mode-section">
        <SettingsSection title="极简低占用后台模式">
          <SettingsRow
            title="立即进入极简后台模式"
            subtitle="关闭主窗口并释放画廊与缓存内存，仅保留系统托盘、顶部浮窗采集与最近素材横条，随时可从托盘恢复主窗口"
          >
            <SettingsButton
              variant="secondary"
              loading={enteringMinimal}
              data-testid="settings-enter-minimal-mode-btn"
              onClick={async () => {
                setEnteringMinimal(true);
                try {
                  const saved = await getTransport().setMinimalMode(true);
                  setSettings(saved);
                  pushToast({
                    message: '已进入极简后台模式，点击系统托盘图标可随时恢复主窗口',
                    tone: 'info',
                  });
                } catch (err) {
                  pushToast({
                    message: err instanceof Error ? err.message : '进入极简后台模式失败',
                    tone: 'error',
                  });
                } finally {
                  setEnteringMinimal(false);
                }
              }}
            >
              进入极简后台模式
            </SettingsButton>
          </SettingsRow>

          <SettingsCardDivider />

          <SettingsRow
            title="关闭主窗口时自动进入极简后台模式"
            subtitle="开启后关闭主窗口将释放画廊内存并驻留系统托盘，顶部浮窗与最近素材快捷取用保持随时待命"
          >
            <SettingsSwitch
              checked={Boolean(settings.minimalMode)}
              ariaLabel="启用极简低占用后台模式"
              onChange={(minimalMode) => void persistSettings({ minimalMode })}
            />
          </SettingsRow>
        </SettingsSection>
      </div>
    </div>
  );
};

// =========================================================================
// Pane 5: 采集与快捷键 (CaptureShortcutsSettingsPane) — mirrors CaptureShortcutsSettingsPane.swift 1:1
// =========================================================================

const ShortcutRow: React.FC<{ description: string; keys: string }> = ({ description, keys }) => (
  <div className="px-4 py-[10px] flex items-center justify-between gap-3">
    <span className="text-[12.5px] text-[var(--text-primary)] truncate">{description}</span>
    <kbd className="px-2 py-[3px] rounded-[6px] bg-[var(--settings-subtle)] text-[11px] font-semibold font-mono text-[var(--text-secondary)] shrink-0">
      {keys}
    </kbd>
  </div>
);

function normalizeHotkeyToken(raw: string): string {
  return raw
    .trim()
    .split('+')
    .map((part) => part.trim().toLowerCase())
    .filter(Boolean)
    .join('+');
}

function validateHotkeys(cfg: HotkeyConfig): string | null {
  const keys = [cfg.captureArea.trim(), cfg.toggleShelf.trim(), cfg.collectClipboard.trim()];
  if (keys.some((k) => k.length === 0)) {
    return '全局快捷键不能为空，请填写或点击「恢复默认」';
  }
  const normalized = keys.map(normalizeHotkeyToken);
  if (new Set(normalized).size < normalized.length) {
    return '三个全局快捷键不能重复，请修改后再保存';
  }
  return null;
}

export const CaptureShortcutsSettingsPane: React.FC = () => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const setStatusFeedback = useSyncAIStore((s) => s.setStatusFeedback);
  const [hotkeys, setHotkeys] = useState<HotkeyConfig>(DEFAULT_HOTKEYS);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    void getTransport()
      .getDesktopIntegrationStatus()
      .then((st) => setHotkeys(st.hotkeys))
      .catch(() => {});
  }, []);

  const validationError = validateHotkeys(hotkeys);

  const persistHotkeys = async (next: HotkeyConfig, quiet = false, fallbackPrev?: HotkeyConfig) => {
    const trimmed: HotkeyConfig = {
      enabled: next.enabled,
      captureArea: next.captureArea.trim(),
      toggleShelf: next.toggleShelf.trim(),
      collectClipboard: next.collectClipboard.trim(),
    };
    const errText = validateHotkeys(trimmed);
    if (errText) {
      setStatusFeedback(null, errText);
      pushToast({ message: errText, tone: 'error' });
      return;
    }
    setSaving(true);
    try {
      const saved = await getTransport().updateHotkeys(trimmed);
      setHotkeys(saved);
      if (!quiet) {
        setStatusFeedback('全局快捷键已保存并立即生效', null);
        pushToast({ message: '全局快捷键已保存并立即生效', tone: 'success' });
      }
    } catch (err) {
      if (fallbackPrev) setHotkeys(fallbackPrev);
      const msg = err instanceof Error ? err.message : '保存快捷键失败';
      setStatusFeedback(null, msg);
      pushToast({ message: msg, tone: 'error' });
    } finally {
      setSaving(false);
    }
  };

  return (
    <div data-testid="settings-pane-captureShortcuts" className="flex flex-col gap-[22px]">
      <SettingsSection title="系统权限与全局采集">
        <SettingsRow
          title="区域截图与剪贴板采集"
          subtitle="已就绪 · 无需额外系统权限，可随时在其他应用中使用全局快捷键截图或收藏剪贴板"
          subtitleTone="positive"
        >
          <SettingsStatusBadge text="已就绪" tone="positive" />
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="启用系统全局快捷键"
          subtitle={`在任意应用中通过 ${hotkeys.captureArea} 区域截图、${hotkeys.collectClipboard} 收藏剪贴板、${hotkeys.toggleShelf} 展开顶部浮窗`}
        >
          <SettingsSwitch
            checked={hotkeys.enabled}
            disabled={saving}
            ariaLabel="启用系统全局快捷键"
            onChange={(enabled) => {
              const prev = hotkeys;
              const next = { ...hotkeys, enabled };
              setHotkeys(next);
              void persistHotkeys(next, true, prev);
            }}
          />
        </SettingsRow>

        <SettingsCardDivider />

        <div className="px-4 py-3.5 flex flex-col gap-3">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-2.5">
            <label className="flex flex-col gap-1 text-[11.5px]">
              <span className="text-[var(--text-secondary)] inline-flex items-center gap-1">
                <Camera size={12} />
                区域截图
              </span>
              <SettingsInput
                type="text"
                value={hotkeys.captureArea}
                onChange={(e) => setHotkeys({ ...hotkeys, captureArea: e.target.value })}
                className="font-mono"
              />
            </label>
            <label className="flex flex-col gap-1 text-[11.5px]">
              <span className="text-[var(--text-secondary)] inline-flex items-center gap-1">
                <PanelTop size={12} />
                呼出顶部浮窗
              </span>
              <SettingsInput
                type="text"
                value={hotkeys.toggleShelf}
                onChange={(e) => setHotkeys({ ...hotkeys, toggleShelf: e.target.value })}
                className="font-mono"
              />
            </label>
            <label className="flex flex-col gap-1 text-[11.5px]">
              <span className="text-[var(--text-secondary)] inline-flex items-center gap-1">
                <Clipboard size={12} />
                收藏剪贴板
              </span>
              <SettingsInput
                type="text"
                value={hotkeys.collectClipboard}
                onChange={(e) => setHotkeys({ ...hotkeys, collectClipboard: e.target.value })}
                className="font-mono"
              />
            </label>
          </div>

          {validationError && (
            <div className="text-[11.5px] text-[var(--settings-warning)]">{validationError}</div>
          )}

          <div className="flex items-center justify-end gap-2">
            <SettingsButton
              variant="secondary"
              disabled={saving}
              onClick={() => void persistHotkeys({ ...DEFAULT_HOTKEYS, enabled: hotkeys.enabled })}
            >
              恢复默认
            </SettingsButton>
            <SettingsButton
              variant="primary"
              loading={saving}
              disabled={Boolean(validationError)}
              onClick={() => void persistHotkeys(hotkeys)}
            >
              保存快捷键
            </SettingsButton>
          </div>
        </div>
      </SettingsSection>

      <SettingsSection title="全局采集快捷键">
        <ShortcutRow description="区域截图并收入目标" keys={hotkeys.captureArea} />
        <SettingsCardDivider />
        <ShortcutRow description="一键收藏当前剪贴板（含 X 推文与媒体）" keys={hotkeys.collectClipboard} />
        <SettingsCardDivider />
        <ShortcutRow description="展开 / 收起顶部灵感浮窗" keys={hotkeys.toggleShelf} />
      </SettingsSection>

      <SettingsSection title="画廊与整理">
        <ShortcutRow description="快速预览素材 / 再按一次退出" keys="Space" />
        <SettingsCardDivider />
        <ShortcutRow description="快速跳转情绪板、文件夹或素材" keys="Ctrl + J" />
        <SettingsCardDivider />
        <ShortcutRow description="快速采集网址、文字或色卡" keys="Ctrl + N" />
        <SettingsCardDivider />
        <ShortcutRow description="展开 / 收起视觉与配色筛选条" keys="Ctrl + Shift + S" />
        <SettingsCardDivider />
        <ShortcutRow description="收起 / 展开侧边栏为仅图标" keys="Ctrl + \" />
        <SettingsCardDivider />
        <ShortcutRow description="切换瀑布流 / 等高行 / 画廊 / 环形画廊" keys="Ctrl + 1 / 2 / 3 / 4" />
        <SettingsCardDivider />
        <ShortcutRow description="收件箱快速归档到对应文件夹" keys="1 – 9" />
        <SettingsCardDivider />
        <ShortcutRow description="拷贝所选素材原文件到剪贴板" keys="Ctrl + C" />
      </SettingsSection>

      <SettingsSection title="情绪板画布">
        <ShortcutRow description="顺时针 / 逆时针旋转 90°" keys="R / Shift + R" />
        <SettingsCardDivider />
        <ShortcutRow description="水平 / 上下翻转素材" keys="Shift + H / Shift + V" />
        <SettingsCardDivider />
        <ShortcutRow description="画布自由平移查看" keys="空格拖拽 / 鼠标中键拖拽" />
        <SettingsCardDivider />
        <ShortcutRow description="画布撤销 / 重做" keys="Ctrl + Z / Ctrl + Shift + Z" />
      </SettingsSection>
    </div>
  );
};

// =========================================================================
// Pane 8: 插件与扩展 (ExtensionsSettingsPane) — mirrors ExtensionsSettingsPane.swift 1:1
// =========================================================================

function maskBridgeToken(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return '••••••••••••';
  if (trimmed.length <= 6) return '••••••••••••';
  return `••••••••••••${trimmed.slice(-6)}`;
}

export const ExtensionsSettingsPane: React.FC = () => {
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const setStatusFeedback = useSyncAIStore((s) => s.setStatusFeedback);
  const openDirectoryInExplorer = useSyncAIStore((s) => s.openDirectoryInExplorer);
  const [exportedPath, setExportedPath] = useState<string | null>(null);
  const [bridge, setBridge] = useState<ExtensionBridgeStateDto | null>(null);
  const [bridgeBusy, setBridgeBusy] = useState(false);
  const [revealingExt, setRevealingExt] = useState(false);
  const [regeneratingToken, setRegeneratingToken] = useState(false);
  const [revealToken, setRevealToken] = useState(false);

  useEffect(() => {
    let active = true;
    void getTransport()
      .getExtensionBridgeState()
      .then((state) => {
        if (active) setBridge(state);
      })
      .catch(() => {});
    return () => {
      active = false;
    };
  }, []);

  const copyToClipboard = async (text: string, message: string) => {
    try {
      await navigator.clipboard?.writeText(text);
      setStatusFeedback(message, null);
      pushToast({ message, tone: 'success' });
    } catch {
      const msg = '复制到剪贴板失败';
      setStatusFeedback(null, msg);
      pushToast({ message: msg, tone: 'error' });
    }
  };

  const handleToggleBridge = async (enabled: boolean) => {
    setBridgeBusy(true);
    try {
      const next = await getTransport().setExtensionBridgeEnabled(enabled);
      setBridge(next);
      const msg = next.running
        ? '已开启浏览器扩展本地连接桥接'
        : enabled
          ? next.lastError || '浏览器扩展桥接启动受阻'
          : '已暂停浏览器扩展本地连接桥接';
      setStatusFeedback(enabled && !next.running ? null : msg, enabled && !next.running ? msg : null);
      pushToast({ message: msg, tone: enabled && !next.running ? 'error' : 'info' });
    } catch (err) {
      const msg = err instanceof Error ? err.message : '切换本地连接桥接失败';
      setStatusFeedback(null, msg);
      pushToast({ message: msg, tone: 'error' });
    } finally {
      setBridgeBusy(false);
    }
  };

  const handleToggleAutoPair = async (allowLocalAutoPair: boolean) => {
    setBridgeBusy(true);
    try {
      const next = await getTransport().setExtensionAutoPair(allowLocalAutoPair);
      setBridge(next);
      const msg = allowLocalAutoPair
        ? '已开启同机扩展自动免密配对'
        : '已关闭自动免密配对，扩展连接将校验手动令牌';
      setStatusFeedback(msg, null);
      pushToast({ message: msg, tone: 'info' });
    } catch (err) {
      const msg = err instanceof Error ? err.message : '切换自动配对设置失败';
      setStatusFeedback(null, msg);
      pushToast({ message: msg, tone: 'error' });
    } finally {
      setBridgeBusy(false);
    }
  };

  const handleRevealExtension = async () => {
    setRevealingExt(true);
    try {
      const revealedPath = await getTransport().revealBundledBrowserExtension();
      const msg = revealedPath
        ? '已在文件资源管理器中定位浏览器扩展目录'
        : '已打开浏览器扩展目录';
      setStatusFeedback(msg, null);
      pushToast({ message: msg, tone: 'success' });
    } catch (err) {
      const msg = err instanceof Error ? err.message : '无法定位内置浏览器扩展目录';
      setStatusFeedback(null, msg);
      pushToast({ message: msg, tone: 'error' });
    } finally {
      setRevealingExt(false);
    }
  };

  const handleRegenerateToken = async () => {
    setRegeneratingToken(true);
    try {
      const next = await getTransport().regenerateExtensionBridgeToken();
      setBridge(next);
      const msg = next.allowLocalAutoPair
        ? '已重新生成访问令牌，已配对的本机扩展将在下次使用时自动更新'
        : '已重新生成访问令牌，请在浏览器扩展中手动更新令牌';
      setStatusFeedback(msg, null);
      pushToast({ message: msg, tone: 'success' });
    } catch (err) {
      const msg = err instanceof Error ? err.message : '重新生成访问令牌失败';
      setStatusFeedback(null, msg);
      pushToast({ message: msg, tone: 'error' });
    } finally {
      setRegeneratingToken(false);
    }
  };

  const handleExportPlugin = async () => {
    const dir = await getTransport().pickDirectoryDialog('选择导出 Figma 插件文件夹的位置');
    if (!dir) return;
    try {
      const dest = await getTransport().exportFigmaPluginBundle(dir);
      setExportedPath(dest);
      setStatusFeedback(`已导出 Figma 插件目录至 ${dest}`, null);
      pushToast({ message: `已导出 Figma 插件目录至 ${dest}`, tone: 'success' });
    } catch (err) {
      const msg = `导出插件失败：${err instanceof Error ? err.message : String(err)}`;
      setStatusFeedback(null, msg);
      pushToast({ message: msg, tone: 'error' });
    }
  };

  const manifestPath = exportedPath ? `${exportedPath}\\manifest.json` : null;
  const bridgeEnabled = bridge?.enabled ?? false;
  const bridgeRunning = bridge?.running ?? false;
  const bridgePort = bridge?.port ?? 41937;
  const bridgeBaseUrl = bridge?.baseUrl || `http://127.0.0.1:${bridgePort}`;
  const bridgeBadgeText = bridgeRunning
    ? '已就绪'
    : !bridgeEnabled
      ? '已暂停'
      : '启动受阻';
  const bridgeBadgeTone: 'positive' | 'neutral' | 'warning' = bridgeRunning
    ? 'positive'
    : !bridgeEnabled
      ? 'neutral'
      : 'warning';
  const bridgeSubtitleTone: 'default' | 'positive' | 'warning' = bridgeRunning
    ? 'positive'
    : bridgeEnabled && !bridgeRunning
      ? 'warning'
      : 'default';
  const bundledExtDir = bridge?.bundledExtensionDir?.trim() || null;

  return (
    <div data-testid="settings-pane-extensions" className="flex flex-col gap-[22px]">
      <div data-testid="settings-browser-extension-section">
        <SettingsSection title="浏览器扩展（Chrome / Edge / Arc / Brave）">
          <SettingsRow
            title="桌面端本地连接桥接"
            subtitle={
              <span className="flex flex-col gap-0.5">
                <span>
                  {bridgeRunning
                    ? `监听本机 http://127.0.0.1:${bridgePort} · 仅限本机回环访问，开启后浏览器扩展可一键收藏网页、小红书笔记、X 推文与图片`
                    : '开启后浏览器扩展即可自动连接 Charkle 桌面端'}
                </span>
                {bridge?.lastError && (
                  <span className="text-[var(--settings-warning)]">{bridge.lastError}</span>
                )}
              </span>
            }
            subtitleTone={bridgeSubtitleTone}
          >
            <SettingsStatusBadge text={bridgeBadgeText} tone={bridgeBadgeTone} />
            <SettingsSwitch
              checked={bridgeEnabled}
              disabled={bridgeBusy || !bridge}
              ariaLabel="启用桌面端本地连接桥接"
              onChange={(checked) => void handleToggleBridge(checked)}
            />
          </SettingsRow>

          <SettingsCardDivider />

          <SettingsRow
            title="同机扩展自动免密配对"
            subtitle="允许本机已安装的浏览器扩展自动完成配对，无需手动复制服务地址与令牌（严格拒绝普通网页与 localhost 页面）"
            disabled={!bridgeEnabled}
          >
            <SettingsSwitch
              checked={Boolean(bridge?.allowLocalAutoPair)}
              disabled={bridgeBusy || !bridge || !bridgeEnabled}
              ariaLabel="允许同机扩展自动免密配对"
              onChange={(checked) => void handleToggleAutoPair(checked)}
            />
          </SettingsRow>

          <SettingsCardDivider />

          <SettingsRow
            title="安装 Charkle 浏览器扩展"
            subtitle={
              bundledExtDir ? (
                <span className="flex flex-col gap-0.5">
                  <span>
                    已内置扩展程序目录 · 加载后自动连接本机素材库，支持网页抓图与 X / 小红书批量导入
                  </span>
                  <span className="font-mono text-[11px] text-[var(--text-tertiary)] break-all">
                    {bundledExtDir}
                  </span>
                </span>
              ) : (
                '未在当前路径找到内置浏览器扩展目录，请使用正式安装的 Charkle 桌面端'
              )
            }
          >
            {bundledExtDir && (
              <SettingsButton
                variant="secondary"
                onClick={() => void copyToClipboard(bundledExtDir, '已复制浏览器扩展目录路径')}
              >
                <Copy size={12} />
                复制扩展目录
              </SettingsButton>
            )}
            <SettingsButton
              variant="primary"
              loading={revealingExt}
              disabled={!bridge}
              data-testid="reveal-browser-extension-btn"
              onClick={() => void handleRevealExtension()}
            >
              <FolderOpen size={12.5} />
              在资源管理器中定位扩展
            </SettingsButton>
          </SettingsRow>

          <InlineGuideDisclosure title="如何安装浏览器扩展（仅首次需要，3 步）">
            <SettingsGuideStep
              number="1"
              title="点击上方「在资源管理器中定位扩展」，自动定位内置的 BrowserExtension 目录"
            />
            <SettingsGuideStep
              number="2"
              title="在 Chrome / Edge / Arc / Brave 地址栏打开扩展管理页（如 edge://extensions 或 chrome://extensions），开启右上角「开发人员模式」"
            />
            <SettingsGuideStep
              number="3"
              title="点击「加载解压缩的扩展程序」并选择 BrowserExtension 目录即可完成；随后点开扩展图标将自动连接本机 Charkle"
            />
          </InlineGuideDisclosure>

          <SettingsCardDivider />

          <InlineGuideDisclosure
            title="高级：手动连接地址与访问令牌"
            defaultExpanded={false}
          >
            <div className="flex flex-col gap-3 py-0.5">
              <div className="flex items-center justify-between gap-3">
                <div className="min-w-0 flex-1 flex flex-col gap-0.5">
                  <span className="text-[12px] font-semibold text-[var(--text-primary)]">
                    本机桥接地址
                  </span>
                  <span className="font-mono text-[11.5px] text-[var(--text-secondary)] select-all break-all">
                    {bridgeBaseUrl}
                  </span>
                </div>
                <SettingsButton
                  variant="secondary"
                  onClick={() => void copyToClipboard(bridgeBaseUrl, '已复制本机桥接地址')}
                >
                  <Copy size={12} />
                  复制地址
                </SettingsButton>
              </div>

              <div className="h-px bg-[var(--settings-divider)]" />

              <div className="flex items-center justify-between gap-3">
                <div className="min-w-0 flex-1 flex flex-col gap-0.5">
                  <span className="text-[12px] font-semibold text-[var(--text-primary)]">
                    访问令牌
                  </span>
                  <span
                    data-testid="extension-bridge-token-value"
                    className="font-mono text-[11.5px] text-[var(--text-secondary)] select-all break-all"
                  >
                    {revealToken
                      ? bridge?.accessToken || ''
                      : maskBridgeToken(bridge?.accessToken ?? '')}
                  </span>
                </div>
                <div className="shrink-0 flex items-center gap-1.5">
                  <SettingsButton
                    variant="secondary"
                    onClick={() => setRevealToken((prev) => !prev)}
                  >
                    {revealToken ? <EyeOff size={12} /> : <Eye size={12} />}
                    {revealToken ? '隐藏' : '显示'}
                  </SettingsButton>
                  <SettingsButton
                    variant="secondary"
                    disabled={!bridge?.accessToken}
                    onClick={() =>
                      bridge?.accessToken &&
                      void copyToClipboard(bridge.accessToken, '已复制访问令牌')
                    }
                  >
                    <Copy size={12} />
                    复制令牌
                  </SettingsButton>
                  <SettingsButton
                    variant="secondary"
                    loading={regeneratingToken}
                    disabled={!bridge}
                    data-testid="regenerate-extension-token-btn"
                    onClick={() => void handleRegenerateToken()}
                  >
                    <RefreshCw
                      size={12}
                      className={regeneratingToken ? 'animate-spin motion-reduce:animate-none' : ''}
                    />
                    重新生成令牌
                  </SettingsButton>
                </div>
              </div>
            </div>
          </InlineGuideDisclosure>
        </SettingsSection>
      </div>

      <SettingsSection title="Figma 与 FigJam">
        <SettingsRow
          title="Charkle → Figma / FigJam Bridge"
          subtitle="已内置于 Charkle · 纯本地离线导入，无需 API 密钥，无损保留独立图层、原图像素与 GIF"
          subtitleTone="positive"
        >
          <SettingsButton variant="primary" onClick={() => void handleExportPlugin()}>
            <Download size={13} />
            导出插件包…
          </SettingsButton>
        </SettingsRow>

        <InlineGuideDisclosure title="如何在 Figma 桌面端导入（仅首次需要，3 步）">
          <SettingsGuideStep number="1" title="打开 Figma 桌面端的任意 Design 或 FigJam 文件" />
          <SettingsGuideStep
            number="2"
            title="点击左上角 Figma 主菜单，选择：Plugins → Development → Import plugin from manifest…"
          />
          <SettingsGuideStep
            number="3"
            title="选择导出的 Charkle-Figma-Plugin 目录中的 manifest.json 即可完成安装"
            detail="提示：导出后点击下方「复制路径」可直接粘贴到文件选择框定位。"
          />
        </InlineGuideDisclosure>

        {exportedPath && manifestPath && (
          <>
            <SettingsCardDivider />
            <SettingsRow
              title="插件清单路径（manifest.json）"
              subtitle={<span className="font-mono text-[11px] break-all">{manifestPath}</span>}
            >
              <SettingsButton
                variant="secondary"
                onClick={() => void openDirectoryInExplorer(exportedPath)}
              >
                <FolderOpen size={12.5} />
                打开目录
              </SettingsButton>
              <SettingsButton
                variant="secondary"
                onClick={() =>
                  void copyToClipboard(manifestPath, '已复制 Figma 插件 manifest.json 路径')
                }
              >
                复制路径
              </SettingsButton>
            </SettingsRow>
          </>
        )}

        <SettingsCardDivider />

        <SettingsRow
          title="如何使用 .charkleboard 导出与导入"
          subtitle="保留图片、便签、区域分组、矢量色卡、连线箭头与手绘批注"
        />

        <InlineGuideDisclosure title="查看情绪板导入 Figma / FigJam 完整流程">
          <SettingsGuideStep
            number="1"
            title="在 Charkle 打开任意情绪板，点击右侧面板的「导出至 Figma / FigJam」"
            detail="Charkle 会生成一份无损 .charkleboard 打包文件（超大图片自动无损切块，GIF 保留原字节）。"
          />
          <SettingsGuideStep
            number="2"
            title="在 Figma / FigJam 中运行「Charkle → Figma Bridge」插件，拖入该文件"
            detail="所有对象都会以原生可编辑图层落地画布，方便继续二次创作。"
          />
        </InlineGuideDisclosure>
      </SettingsSection>
    </div>
  );
};

// =========================================================================
// Pane 9: 高级与关于 (AdvancedAboutSettingsPane) — mirrors AdvancedAboutSettingsPane.swift 1:1
// =========================================================================

export const AdvancedAboutSettingsPane: React.FC = () => {
  const openOnboarding = useCoordinatorStore((s) => s.openOnboarding);
  const surfaceState = useCoordinatorStore((s) => s.surfaceState);
  const destination = useCoordinatorStore((s) => s.destination);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const assets = useLibraryStore((s) => s.assets);
  const refreshAll = useLibraryStore((s) => s.refreshAll);

  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const diagnostics = useSyncAIStore((s) => s.diagnostics);
  const hasGoogleOAuthClient = useSyncAIStore((s) => s.hasGoogleOAuthClient);
  const syncing = useSyncAIStore((s) => s.syncing);
  const rebuildingVisualIndex = useSyncAIStore((s) => s.rebuildingVisualIndex);
  const rebuildProgress = useSyncAIStore((s) => s.rebuildVisualIndexProgress);
  const saveSyncConfig = useSyncAIStore((s) => s.saveSyncConfig);
  const syncNow = useSyncAIStore((s) => s.syncNow);
  const rebuildLocalVisualIndex = useSyncAIStore((s) => s.rebuildLocalVisualIndex);
  const openDirectoryInExplorer = useSyncAIStore((s) => s.openDirectoryInExplorer);
  const refreshSettingsData = useSyncAIStore((s) => s.refreshSettingsData);

  const [draftSync, setDraftSync] = useState<DriveSyncConfig>(syncConfig ?? DEFAULT_SYNC_CONFIG);
  const [showOAuthModal, setShowOAuthModal] = useState(false);
  const [showMountModal, setShowMountModal] = useState(false);

  useEffect(() => {
    if (syncConfig) setDraftSync(syncConfig);
  }, [syncConfig]);

  const gdirect = diagnostics?.gdirect;
  const healthyNodeCount = (gdirect?.endpoints ?? []).filter((e) => e.healthy).length;
  const hasGDirectCli = Boolean(gdirect?.cliPath);
  const isMountActive = Boolean(gdirect?.isMountActive);

  const persistSyncQuiet = (next: DriveSyncConfig) => {
    setDraftSync(next);
    void saveSyncConfig(next, undefined, { quiet: true });
  };

  const copyDiagnostics = async () => {
    const payload = JSON.stringify(
      {
        appVersion: diagnostics?.appVersion ?? '1.0.1',
        schemaVersion: diagnostics?.schemaVersion ?? 2,
        dataDir: diagnostics?.dataDir,
        databasePath: diagnostics?.databasePath,
        surface: surfaceState,
        ocr: diagnostics?.ocr,
        gdirect: diagnostics?.gdirect,
      },
      null,
      2,
    );
    try {
      await navigator.clipboard?.writeText(payload);
      pushToast({ message: '已复制系统诊断快照到剪贴板', tone: 'success' });
    } catch {
      pushToast({ message: '复制系统诊断快照失败', tone: 'error' });
    }
  };

  return (
    <div data-testid="settings-pane-advancedAbout" className="flex flex-col gap-[22px]">
      {/* 1. Google Drive Advanced Channel (gdirect & Mounted Volume) */}
      <SettingsSection title="Google Drive 高级通道（gdirect）">
        <SettingsRow
          title="Google 登录凭据（OAuth Client）"
          subtitle={
            hasGoogleOAuthClient
              ? '已配置桌面端凭据，可直接用于 Google Drive 直连登录'
              : '尚未配置，可导入 client_secret.json 或粘贴桌面端凭据'
          }
          subtitleTone={hasGoogleOAuthClient ? 'positive' : 'default'}
        >
          <SettingsButton variant="secondary" onClick={() => setShowOAuthModal(true)}>
            {hasGoogleOAuthClient ? '管理凭据…' : '配置凭据…'}
          </SettingsButton>
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="网络受限时使用本机 gdirect 兜底"
          subtitle={
            !hasGDirectCli
              ? '未检测到本机 gdirect CLI；安装后可在网络受限时自动回退优选节点'
              : draftSync.useGDirectIPAcceleration
                ? healthyNodeCount > 0
                  ? `已开启 · 检测到 ${healthyNodeCount} 个健康节点（仅当标准 HTTPS 直连受阻时自动启用）`
                  : '已开启 · 当无法直连 googleapis.com 时自动尝试本机 gdirect'
                : '已关闭 · 仅使用标准 Google Drive HTTPS 直连'
          }
          disabled={!hasGDirectCli}
        >
          <SettingsSwitch
            checked={draftSync.useGDirectIPAcceleration}
            disabled={!hasGDirectCli}
            ariaLabel="网络受限时使用本机 gdirect 兜底"
            onChange={(useGDirectIPAcceleration) =>
              persistSyncQuiet({ ...draftSync, useGDirectIPAcceleration })
            }
          />
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="本地挂载盘模式（Windows 盘符 / gdirect）"
          subtitle={
            draftSync.mode === 'gdirectMount'
              ? isMountActive
                ? `当前已启用 · 挂载目录：${draftSync.mountPath}`
                : `当前已选择挂载模式，但尚未检测到 ${draftSync.mountPath} 就绪`
              : '默认推荐使用免挂载直连 API；仅限习惯在资源管理器中直接访问挂载盘的用户'
          }
          subtitleTone={draftSync.mode === 'gdirectMount' && isMountActive ? 'positive' : 'default'}
        >
          <SettingsButton variant="secondary" onClick={() => setShowMountModal(true)}>
            挂载与切换…
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>

      {/* 2. Index & Data Maintenance */}
      <SettingsSection title="索引与数据维护">
        <div>
          <SettingsRow
            title="重建本机视觉与文字索引"
            subtitle={
              rebuildProgress
                ? `正在离线重建配色、OCR 与视觉相似特征（${rebuildProgress.completed} / ${rebuildProgress.total}）…`
                : `当发现部分素材缺少配色、文字识别或相似推荐时，可离线重新扫描全库（当前已加载 ${assets.length} 项）`
            }
          >
            <SettingsButton
              variant="secondary"
              loading={rebuildingVisualIndex}
              onClick={async () => {
                await rebuildLocalVisualIndex(assets.map((a) => a.id));
                await refreshAll(destination);
              }}
            >
              <RefreshCw
                size={12}
                className={rebuildingVisualIndex ? 'animate-spin motion-reduce:animate-none' : ''}
              />
              {rebuildingVisualIndex ? '扫描中…' : '开始扫描'}
            </SettingsButton>
          </SettingsRow>

          {rebuildProgress && rebuildProgress.total > 0 && (
            <div className="px-4 pb-3">
              <div className="h-1.5 w-full rounded-full bg-[var(--settings-subtle)] overflow-hidden">
                <div
                  style={{
                    transform: `scaleX(${Math.max(0.08, Math.min(1, rebuildProgress.completed / rebuildProgress.total))})`,
                  }}
                  className="h-full w-full origin-left rounded-full bg-[var(--accent)] transition-transform duration-200 motion-reduce:transition-none"
                />
              </div>
            </div>
          )}
        </div>

        <SettingsCardDivider />

        <SettingsRow
          title="打开应用数据目录"
          subtitle={
            <span className="font-mono text-[11px] break-all">
              {diagnostics?.dataDir ?? '%APPDATA%\\app.charkle.windows'}
            </span>
          }
        >
          <SettingsButton
            variant="secondary"
            onClick={() => void openDirectoryInExplorer(diagnostics?.dataDir ?? '')}
          >
            <FolderOpen size={13} />
            打开目录
          </SettingsButton>
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="快速上手引导"
          subtitle="重新打开 6 步交互式引导，逐项核对素材库存储、顶部浮窗、AI 与外观设置"
        >
          <SettingsButton variant="secondary" onClick={openOnboarding}>
            <RotateCcw size={13} />
            重新运行新手引导
          </SettingsButton>
        </SettingsRow>

        <SettingsCardDivider />

        <SettingsRow
          title="系统诊断快照"
          subtitle={`离线文字识别语言：${(diagnostics?.ocr.availableLanguages ?? []).join('、') || '默认系统语言'}`}
        >
          <SettingsButton variant="secondary" onClick={() => void copyDiagnostics()}>
            <Copy size={13} />
            复制诊断快照
          </SettingsButton>
        </SettingsRow>
      </SettingsSection>

      {/* 3. About Charkle */}
      <SettingsSection title="关于 Charkle">
        <div className="px-4 py-3.5 flex items-center gap-3.5">
          <CharkleBrandMark size={44} />
          <div className="min-w-0 flex-1 flex flex-col gap-0.5">
            <div className="flex items-center gap-2">
              <span className="text-[14px] font-semibold text-[var(--text-primary)]">Charkle</span>
              <span className="text-[11px] font-medium font-mono text-[var(--text-secondary)] charkle-tabular">
                v{diagnostics?.appVersion ?? '1.0.1'}
              </span>
            </div>
            <span className="text-[11.5px] text-[var(--text-secondary)]">
              面向设计师的视觉素材库与 10 秒情绪板创作台 · 本机离线视觉引擎 + 可读云端存储
            </span>
          </div>
        </div>
      </SettingsSection>

      {/* Sub-Modal 1: Google OAuth Setup (Save only, no auto sign-in) */}
      <GoogleOAuthSetupModal
        open={showOAuthModal}
        onClose={() => setShowOAuthModal(false)}
        autoSignInAfterSave={false}
      />

      {/* Sub-Modal 2: Local Mount Management Sheet (mirrors gdirectMountSheet) */}
      <SettingsSubModal
        open={showMountModal}
        onClose={() => {
          if (
            !syncConfig ||
            draftSync.mode !== syncConfig.mode ||
            draftSync.mountPath !== syncConfig.mountPath
          ) {
            persistSyncQuiet(draftSync);
          }
          setShowMountModal(false);
        }}
        title={
          <span className="inline-flex items-center gap-2">
            <HardDrive size={16} />
            <span>本地挂载盘管理</span>
          </span>
        }
        subtitle="将 Google Drive Desktop / OneDrive / SMB / gdirect 映射盘作为本地目录接入。"
        width="md"
        footer={
          <>
            <SettingsButton
              variant="secondary"
              onClick={() => void refreshSettingsData()}
            >
              刷新挂载状态
            </SettingsButton>
            {draftSync.mode === 'gdirectMount' && isMountActive && (
              <SettingsButton
                variant="secondary"
                loading={syncing}
                onClick={() => void syncNow()}
              >
                立即同步
              </SettingsButton>
            )}
            <SettingsButton
              variant="primary"
              onClick={() => {
                persistSyncQuiet(draftSync);
                setShowMountModal(false);
              }}
            >
              完成
            </SettingsButton>
          </>
        }
      >
        <div className="rounded-[10px] bg-[var(--settings-subtle)] p-3 flex items-center justify-between gap-3">
          <div className="min-w-0">
            <div className="text-[12.5px] font-medium text-[var(--text-primary)]">
              Google Drive 接入模式
            </div>
            <div className="text-[11px] text-[var(--text-secondary)] mt-0.5">
              若映射盘离线或断连，可随时切回「正常直连（推荐）」
            </div>
          </div>
          <SegmentedControl<DriveTransportMode>
            value={draftSync.mode === 'gdirectMount' ? 'gdirectMount' : 'directAPIWithGDirect'}
            onChange={(mode) => persistSyncQuiet({ ...draftSync, mode })}
            ariaLabel="Google Drive 接入模式"
            options={[
              { value: 'directAPIWithGDirect', label: '正常直连（推荐）' },
              { value: 'gdirectMount', label: '本地挂载盘' },
            ]}
          />
        </div>

        <label className="flex flex-col gap-1">
          <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">
            本地挂载目录或盘符
          </span>
          <div className="flex gap-2">
            <SettingsInput
              type="text"
              value={draftSync.mountPath}
              onChange={(e) => setDraftSync({ ...draftSync, mountPath: e.target.value })}
              onBlur={() => persistSyncQuiet(draftSync)}
              placeholder="G:\"
              className="flex-1"
            />
            <SettingsButton
              variant="secondary"
              onClick={async () => {
                const picked = await getTransport().pickDirectoryDialog('选择挂载根目录');
                if (picked) persistSyncQuiet({ ...draftSync, mountPath: picked });
              }}
            >
              浏览…
            </SettingsButton>
          </div>
        </label>

        <div className="rounded-[9px] bg-[var(--settings-subtle)] px-3 py-2 flex items-center justify-between text-[11.5px]">
          <span className="text-[var(--text-secondary)]">
            当前卷状态：{isMountActive ? '卷已就绪' : '未检测到活跃挂载路径'}
          </span>
          <SettingsStatusBadge
            text={hasGDirectCli ? 'gdirect 已安装' : 'gdirect 未安装'}
            tone={hasGDirectCli ? 'positive' : 'neutral'}
          />
        </div>
      </SettingsSubModal>
    </div>
  );
};
