import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Camera,
  Clipboard,
  Copy,
  Keyboard,
  Minus,
  Monitor,
  Moon,
  PanelLeft,
  PanelRight,
  PanelTop,
  Plus,
  RefreshCw,
  Search,
  Settings,
  Square,
  Sun,
  X,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import { Button, CharkleBrandMark, Popover, type ThemeMode } from '../../design-system';
import { useCoordinatorStore, useSyncAIStore } from '../../stores';
import {
  wireDateToMs,
  type DesktopIntegrationStatus,
  type DriveTransportMode,
  type SyncStatus,
} from '../../types/domain';

const NEXT_THEME: Record<ThemeMode, ThemeMode> = {
  system: 'light',
  light: 'dark',
  dark: 'system',
};

const THEME_LABEL: Record<ThemeMode, string> = {
  system: '跟随系统主题',
  light: '浅色主题',
  dark: '深色主题',
};

function formatRelativeSyncTime(value: SyncStatus['lastSyncedAt']): string {
  const ms = wireDateToMs(value);
  if (!ms) return '尚未同步';
  const elapsedSec = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (elapsedSec < 15) return '刚刚';
  if (elapsedSec < 60) return `${elapsedSec} 秒前`;
  if (elapsedSec < 3600) return `${Math.floor(elapsedSec / 60)} 分钟前`;
  if (elapsedSec < 86400) return `${Math.floor(elapsedSec / 3600)} 小时前`;
  const d = new Date(ms);
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  const hh = String(d.getHours()).padStart(2, '0');
  const mi = String(d.getMinutes()).padStart(2, '0');
  return `${mm}-${dd} ${hh}:${mi}`;
}

function syncModeLabel(mode: DriveTransportMode | undefined): string {
  switch (mode) {
    case 'directAPIWithGDirect':
      return 'Google Drive';
    case 'webDAV':
      return 'WebDAV';
    case 'gdirectMount':
      return 'Drive 挂载';
    default:
      return '本地保存';
  }
}

function syncPhaseLabel(status: SyncStatus | null, syncing: boolean, mode?: DriveTransportMode): string {
  if (!status) return syncing ? '同步中…' : syncModeLabel(mode);
  const pctSuffix =
    status.progressFraction != null ? ` ${Math.round(status.progressFraction * 100)}%` : '';
  if (status.phase === 'scanning') return `扫描中${pctSuffix}`;
  if (status.phase === 'merging') return `整理中${pctSuffix}`;
  if (typeof status.phase === 'object') {
    if ('uploading' in status.phase) {
      const { completed, total } = status.phase.uploading;
      return total > 0 ? `上传 ${completed}/${total}` : `上传中${pctSuffix}`;
    }
    if ('downloading' in status.phase) {
      const { completed, total } = status.phase.downloading;
      return total > 0 ? `拉取 ${completed}/${total}` : `拉取中${pctSuffix}`;
    }
    if ('error' in status.phase) return '同步异常';
  }
  if (syncing) return '同步中…';
  const base = syncModeLabel(mode ?? status.activeMode);
  return status.pendingOpCount > 0 ? `${base} · 待传 ${status.pendingOpCount}` : base;
}

const SwitchToggle: React.FC<{
  checked: boolean;
  label: string;
  onChange: (next: boolean) => void;
}> = ({ checked, label, onChange }) => (
  <div className="flex items-center justify-between gap-3">
    <span className="text-[12px] text-[var(--text-primary)]">{label}</span>
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      onClick={() => onChange(!checked)}
      className={[
        'charkle-pressable relative inline-flex h-[18px] w-[32px] shrink-0 items-center rounded-full cursor-pointer transition-colors duration-150',
        'focus-visible:outline-2 focus-visible:outline-[var(--accent)]',
        checked ? 'bg-[var(--accent)]' : 'bg-black/18 dark:bg-white/20',
      ].join(' ')}
    >
      <span
        className="inline-block h-[14px] w-[14px] rounded-full bg-white shadow-xs transition-transform duration-150"
        style={{ transform: checked ? 'translateX(16px)' : 'translateX(2px)' }}
      />
    </button>
  </div>
);

/**
 * Custom 38px frameless Windows titlebar with Win11 Snap Layout maximize-button rect sync,
 * FloatingSyncStatusPopover parity, accessible switch controls, and crisp native caption buttons.
 */
export const Titlebar: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const setThemeMode = useCoordinatorStore((s) => s.setThemeMode);
  const sidebarOpen = useCoordinatorStore((s) => s.sidebarOpen);
  const sidebarCollapsed = useCoordinatorStore((s) => s.sidebarCollapsed);
  const setSidebarOpen = useCoordinatorStore((s) => s.setSidebarOpen);
  const toggleSidebarCollapsed = useCoordinatorStore((s) => s.toggleSidebarCollapsed);
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const toggleInspector = useCoordinatorStore((s) => s.toggleInspector);
  const setJumpOpen = useCoordinatorStore((s) => s.setJumpOpen);
  const setCaptureOpen = useCoordinatorStore((s) => s.setCaptureOpen);
  const openSettings = useCoordinatorStore((s) => s.openSettings);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const syncConfig = useSyncAIStore((s) => s.syncConfig);
  const syncStatus = useSyncAIStore((s) => s.syncStatus);
  const syncing = useSyncAIStore((s) => s.syncing);
  const syncNow = useSyncAIStore((s) => s.syncNow);
  const refreshSyncAndCache = useSyncAIStore((s) => s.refreshSyncAndCache);

  const headerRef = useRef<HTMLElement | null>(null);
  const maxBtnRef = useRef<HTMLButtonElement | null>(null);
  const syncBtnRef = useRef<HTMLButtonElement | null>(null);
  const desktopBtnRef = useRef<HTMLButtonElement | null>(null);
  const [isMaximized, setIsMaximized] = useState(false);
  const [syncPopoverOpen, setSyncPopoverOpen] = useState(false);
  const [desktopMenuOpen, setDesktopMenuOpen] = useState(false);
  const [desktopStatus, setDesktopStatus] = useState<DesktopIntegrationStatus | null>(null);
  const [startingCapture, setStartingCapture] = useState(false);
  const [shelfExpanded, setShelfExpanded] = useState(false);
  const [togglingShelf, setTogglingShelf] = useState(false);

  const loadDesktopStatus = useCallback(() => {
    void getTransport()
      .getDesktopIntegrationStatus()
      .then((status) => {
        setDesktopStatus(status);
        setShelfExpanded(Boolean(status.shelfVisible));
      })
      .catch(() => {});
  }, []);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;
    const transport = getTransport();

    void transport
      .getDesktopIntegrationStatus()
      .then((status) => {
        if (disposed) return;
        setDesktopStatus(status);
        setShelfExpanded(Boolean(status.shelfVisible));
      })
      .catch(() => {});

    void transport
      .subscribeEvents({
        onShelfState: (state) => {
          if (!disposed) {
            setShelfExpanded(Boolean(state.expanded));
          }
        },
      })
      .then((fn) => {
        if (disposed) {
          fn();
          return;
        }
        unlisten = fn;
      })
      .catch(() => {});

    return () => {
      disposed = true;
      unlisten?.();
    };
  }, []);

  const handleStartRegionCapture = async () => {
    if (startingCapture) return;
    setStartingCapture(true);
    try {
      const targetFolderId = destination.type === 'folder' ? destination.id : null;
      const targetBoardId = destination.type === 'moodboard' ? destination.id : null;
      await getTransport().startRegionCapture(targetFolderId, targetBoardId);
    } catch (err) {
      pushToast({
        message: err instanceof Error && err.message ? err.message : '无法启动区域截图',
        tone: 'error',
      });
    } finally {
      setStartingCapture(false);
    }
  };

  const handleToggleShelf = async () => {
    if (togglingShelf) return;
    setTogglingShelf(true);
    try {
      const next = await getTransport().toggleShelf();
      setShelfExpanded(Boolean(next));
    } catch (err) {
      pushToast({
        message: err instanceof Error && err.message ? err.message : '无法切换顶部悬浮窗',
        tone: 'error',
      });
    } finally {
      setTogglingShelf(false);
    }
  };

  const reportMaximizeRect = useCallback(() => {
    const el = maxBtnRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    void getTransport().setMaximizeButtonRect({
      x: Math.round(rect.left * dpr),
      y: Math.round(rect.top * dpr),
      width: Math.round(rect.width * dpr),
      height: Math.round(rect.height * dpr),
    });
  }, []);

  useEffect(() => {
    void getTransport()
      .windowIsMaximized()
      .then((val) => setIsMaximized(val))
      .catch(() => {});

    reportMaximizeRect();
    const headerEl = headerRef.current;
    const maxEl = maxBtnRef.current;
    let observer: ResizeObserver | null = null;
    if (typeof ResizeObserver !== 'undefined') {
      observer = new ResizeObserver(reportMaximizeRect);
      if (headerEl) observer.observe(headerEl);
      if (maxEl) observer.observe(maxEl);
    }
    const handleResize = () => {
      reportMaximizeRect();
      void getTransport()
        .windowIsMaximized()
        .then((val) => setIsMaximized(val))
        .catch(() => {});
    };
    window.addEventListener('resize', handleResize);
    return () => {
      observer?.disconnect();
      window.removeEventListener('resize', handleResize);
      void getTransport().setMaximizeButtonRect(null);
    };
  }, [reportMaximizeRect]);

  useEffect(() => {
    const raf = requestAnimationFrame(reportMaximizeRect);
    return () => cancelAnimationFrame(raf);
  }, [sidebarOpen, sidebarCollapsed, inspectorOpen, reportMaximizeRect]);

  const handleToggleMaximize = async () => {
    try {
      const next = await getTransport().windowToggleMaximize();
      setIsMaximized(next);
      requestAnimationFrame(reportMaximizeRect);
    } catch {
      // Ignored outside desktop window host
    }
  };

  const activeMode = syncConfig?.mode ?? syncStatus?.activeMode ?? 'localOnly';
  const syncBusy =
    syncing ||
    (syncStatus != null &&
      syncStatus.phase !== 'idle' &&
      !(typeof syncStatus.phase === 'object' && 'error' in syncStatus.phase));
  const syncError =
    syncStatus != null && typeof syncStatus.phase === 'object' && 'error' in syncStatus.phase;
  const syncDotClass = syncError
    ? 'bg-[var(--danger)]'
    : syncBusy || (syncStatus?.pendingOpCount ?? 0) > 0
      ? 'bg-[var(--warning)]'
      : activeMode === 'localOnly'
        ? 'bg-[var(--text-tertiary)]'
        : 'bg-[var(--success)]';

  return (
    <header
      ref={headerRef}
      data-tauri-drag-region
      onDoubleClick={(e) => {
        if ((e.target as HTMLElement).closest('button, input, [data-tauri-drag-region="false"]')) return;
        void handleToggleMaximize();
      }}
      className="charkle-mica-chrome charkle-mica-titlebar h-[38px] shrink-0 flex items-center justify-between pl-2.5 pr-0 border-b border-[var(--border-hairline)] select-none z-40"
    >
      {/* Left: Brand mark + Navigation controls */}
      <div className="flex items-center gap-1.5 shrink-0">
        <div
          data-tauri-drag-region
          className="flex items-center gap-2 pr-1.5 cursor-default shrink-0 whitespace-nowrap"
        >
          <CharkleBrandMark size={18} />
          <span className="text-[12.5px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] whitespace-nowrap">
            Charkle
          </span>
        </div>

        <div data-tauri-drag-region="false" className="flex items-center gap-1.5 shrink-0">
          <button
            type="button"
            data-tauri-drag-region="false"
            onClick={() => {
              if (!sidebarOpen) setSidebarOpen(true);
              else toggleSidebarCollapsed();
            }}
            aria-label={!sidebarOpen || sidebarCollapsed ? '展开侧边栏' : '收起侧边栏'}
            title={!sidebarOpen || sidebarCollapsed ? '展开侧边栏 (Ctrl+\\)' : '收起为图标窄栏 (Ctrl+\\)'}
            className={[
              'charkle-pressable h-7 w-7 shrink-0 inline-flex items-center justify-center rounded-[var(--radius-chip)] cursor-pointer',
              sidebarOpen && !sidebarCollapsed
                ? 'text-[var(--text-primary)] bg-[var(--bg-subtle)]/80'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
            ].join(' ')}
          >
            <PanelLeft size={15} />
          </button>

          <button
            type="button"
            data-tauri-drag-region="false"
            onClick={() => setCaptureOpen(true)}
            aria-label="导入或采集素材"
            title="导入素材或采集链接 (Ctrl+N)"
            className="charkle-pressable h-7 px-2 shrink-0 whitespace-nowrap inline-flex items-center gap-1 rounded-[var(--radius-chip)] text-[12px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            <Plus size={14} className="shrink-0" />
            <span className="hidden sm:inline">采集</span>
          </button>

          <button
            type="button"
            data-tauri-drag-region="false"
            disabled={startingCapture}
            onClick={() => void handleStartRegionCapture()}
            aria-label="区域截图采集"
            title="区域截图采集 (Alt+Shift+A)"
            className="charkle-pressable h-7 w-7 shrink-0 inline-flex items-center justify-center rounded-[var(--radius-chip)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer disabled:opacity-50"
          >
            <Camera size={14.5} />
          </button>

          <button
            type="button"
            data-tauri-drag-region="false"
            disabled={togglingShelf}
            aria-pressed={shelfExpanded}
            onClick={() => void handleToggleShelf()}
            aria-label="切换顶部悬浮窗"
            title="显示 / 隐藏顶部悬浮窗 (Alt+Shift+S)"
            className={[
              'charkle-pressable h-7 w-7 shrink-0 inline-flex items-center justify-center rounded-[var(--radius-chip)] cursor-pointer disabled:opacity-50',
              shelfExpanded
                ? 'text-[var(--text-primary)] bg-[var(--bg-subtle)]/80'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
            ].join(' ')}
          >
            <PanelTop size={14.5} />
          </button>
        </div>
      </div>

      {/* Center: Quick Jump Ctrl+J trigger */}
      <div className="flex-1 flex items-center justify-center px-3 min-w-0" data-tauri-drag-region>
        <button
          type="button"
          data-tauri-drag-region="false"
          onClick={() => setJumpOpen(true)}
          aria-label="快速跳转"
          className="charkle-pressable h-[26px] w-full max-w-[300px] px-2.5 inline-flex items-center justify-between gap-2 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)]/75 hover:bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-secondary)] cursor-pointer"
        >
          <span className="inline-flex items-center gap-1.5 min-w-0 truncate">
            <Search size={12.5} className="shrink-0 text-[var(--text-tertiary)]" />
            <span className="truncate">快速跳转文件夹、标签或素材…</span>
          </span>
          <kbd className="text-[10.5px] px-1.5 py-0.5 rounded-[var(--radius-card-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-tertiary)] shrink-0">
            Ctrl+J
          </kbd>
        </button>
      </div>

      {/* Right: Sync + Desktop Quick Controls + Theme + Settings + Inspector + Native Caption Controls */}
      <div data-tauri-drag-region="false" className="flex items-center h-full shrink-0">
        <div data-tauri-drag-region="false" className="flex items-center gap-1 pr-2 shrink-0">
          <button
            ref={syncBtnRef}
            type="button"
            onClick={() => {
              if (activeMode === 'localOnly') {
                openSettings('library');
              } else {
                const next = !syncPopoverOpen;
                setSyncPopoverOpen(next);
                if (next) void refreshSyncAndCache();
              }
            }}
            title={
              activeMode === 'localOnly'
                ? '当前为本地保存，点击打开存储设置'
                : '点击查看云端同步进度与状态'
            }
            aria-label="同步状态"
            className={[
              'charkle-pressable h-7 px-2 shrink-0 whitespace-nowrap inline-flex items-center gap-1.5 rounded-[var(--radius-chip)] text-[11.5px] font-medium cursor-pointer',
              syncError
                ? 'text-[var(--danger)] bg-[var(--danger-soft)]'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
            ].join(' ')}
          >
            {syncBusy ? (
              <RefreshCw size={12.5} className="animate-spin text-[var(--accent)] shrink-0" />
            ) : (
              <span className={`h-[7px] w-[7px] rounded-full shrink-0 ${syncDotClass}`} />
            )}
            <span className="hidden md:inline charkle-tabular whitespace-nowrap">
              {syncPhaseLabel(syncStatus, syncing, activeMode)}
            </span>
          </button>

          <button
            ref={desktopBtnRef}
            type="button"
            onClick={() => {
              const next = !desktopMenuOpen;
              setDesktopMenuOpen(next);
              if (next) loadDesktopStatus();
            }}
            title="全局快捷键与快捷采集"
            aria-label="桌面集成设置"
            className="charkle-pressable h-7 w-7 shrink-0 inline-flex items-center justify-center rounded-[var(--radius-chip)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            <Keyboard size={14.5} />
          </button>

          <button
            type="button"
            onClick={() => void setThemeMode(NEXT_THEME[themeMode])}
            title={`切换外观（当前：${THEME_LABEL[themeMode]}）`}
            aria-label={THEME_LABEL[themeMode]}
            className="charkle-pressable h-7 w-7 shrink-0 inline-flex items-center justify-center rounded-[var(--radius-chip)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            {themeMode === 'light' && <Sun size={14.5} />}
            {themeMode === 'dark' && <Moon size={14.5} />}
            {themeMode === 'system' && <Monitor size={14.5} />}
          </button>

          <button
            type="button"
            onClick={() => openSettings()}
            aria-label="打开设置中心"
            title="打开设置中心 (Ctrl+,)"
            className="charkle-pressable h-7 w-7 shrink-0 inline-flex items-center justify-center rounded-[var(--radius-chip)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            <Settings size={14.5} />
          </button>

          <button
            type="button"
            onClick={toggleInspector}
            aria-label={inspectorOpen ? '隐藏检查器' : '显示检查器'}
            title={inspectorOpen ? '隐藏右侧检查器 (Ctrl+I)' : '显示右侧检查器 (Ctrl+I)'}
            className={[
              'charkle-pressable h-7 w-7 shrink-0 inline-flex items-center justify-center rounded-[var(--radius-chip)] cursor-pointer',
              inspectorOpen
                ? 'text-[var(--text-primary)] bg-[var(--bg-subtle)]/80'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
            ].join(' ')}
          >
            <PanelRight size={15} />
          </button>
        </div>

        {/* Native Windows caption buttons */}
        <div className="flex items-stretch h-full">
          <button
            type="button"
            aria-label="最小化"
            onClick={() => void getTransport().windowMinimize()}
            className="w-[46px] h-full inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)] cursor-pointer transition-colors duration-100"
          >
            <Minus size={14} />
          </button>

          <button
            ref={maxBtnRef}
            type="button"
            aria-label={isMaximized ? '还原窗口' : '最大化'}
            onClick={() => void handleToggleMaximize()}
            className="w-[46px] h-full inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)] cursor-pointer transition-colors duration-100"
          >
            {isMaximized ? <Copy size={12} className="rotate-90" /> : <Square size={12} />}
          </button>

          <button
            type="button"
            aria-label="关闭窗口"
            onClick={() => void getTransport().windowClose()}
            className="w-[46px] h-full inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[#C42B1C] hover:text-white cursor-pointer transition-colors duration-100"
          >
            <X size={15} />
          </button>
        </div>
      </div>

      {/* Cloud Sync Status & Progress Popover (matching macOS FloatingSyncStatusPill) */}
      <Popover
        open={syncPopoverOpen}
        onOpenChange={setSyncPopoverOpen}
        anchorEl={syncBtnRef.current}
        placement="bottom-end"
        className="w-[296px] p-3.5"
      >
        <div className="flex flex-col gap-3 text-[12px]">
          <div className="flex items-center gap-2">
            {syncBusy ? (
              <RefreshCw size={14} className="animate-spin text-[var(--accent)] shrink-0" />
            ) : (
              <span className={`h-2 w-2 rounded-full shrink-0 ${syncDotClass}`} />
            )}
            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-1.5">
                <span className="text-[13px] font-semibold text-[var(--text-primary)] truncate">
                  {syncBusy
                    ? syncPhaseLabel(syncStatus, syncing, activeMode)
                    : (syncStatus?.pendingOpCount ?? 0) > 0
                      ? `有 ${syncStatus?.pendingOpCount} 项待同步`
                      : '云端存储已连接'}
                </span>
                {syncBusy && syncStatus?.progressFraction != null && (
                  <span className="text-[11px] font-semibold charkle-mono charkle-tabular text-[var(--accent)]">
                    {Math.round(syncStatus.progressFraction * 100)}%
                  </span>
                )}
              </div>
              <div className="text-[11px] text-[var(--text-secondary)] truncate">
                {syncModeLabel(activeMode)}
              </div>
            </div>
          </div>

          {syncBusy && (
            <div className="flex flex-col gap-1.5">
              <div className="h-1.5 w-full rounded-full bg-[var(--bg-subtle)] overflow-hidden">
                <div
                  className="h-full bg-[var(--accent)] rounded-full transition-transform duration-150 origin-left"
                  style={{
                    transform: `scaleX(${Math.max(0.08, Math.min(1, syncStatus?.progressFraction ?? 0.35))})`,
                  }}
                />
              </div>
              {syncStatus?.currentDetail && (
                <div className="text-[11px] text-[var(--text-secondary)] truncate">
                  {syncStatus.currentDetail}
                </div>
              )}
            </div>
          )}

          {!syncBusy && syncStatus?.lastError && (
            <div className="p-2 rounded-[var(--radius-settings-inner)] bg-[var(--danger-soft)] text-[11px] text-[var(--danger)] leading-relaxed charkle-wrap-safe">
              {syncStatus.lastError}
            </div>
          )}

          <div className="p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] flex flex-col gap-1.5 text-[11px]">
            <div className="flex items-center justify-between">
              <span className="text-[var(--text-secondary)]">上次同步</span>
              <span className="font-medium text-[var(--text-primary)] charkle-tabular">
                {formatRelativeSyncTime(syncStatus?.lastSyncedAt)}
              </span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-[var(--text-secondary)]">本地待传队列</span>
              <span
                className={[
                  'font-medium charkle-tabular',
                  (syncStatus?.pendingOpCount ?? 0) > 0
                    ? 'text-[var(--warning)]'
                    : 'text-[var(--text-secondary)]',
                ].join(' ')}
              >
                {(syncStatus?.pendingOpCount ?? 0) > 0
                  ? `${syncStatus?.pendingOpCount} 项`
                  : '已清空'}
              </span>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <Button
              variant="primary"
              size="xs"
              disabled={syncBusy}
              onClick={() => void syncNow()}
              className="flex-1 justify-center"
            >
              {syncBusy ? '同步中…' : '立即同步'}
            </Button>
            <Button
              variant="secondary"
              size="xs"
              onClick={() => {
                setSyncPopoverOpen(false);
                openSettings('sync');
              }}
            >
              存储设置…
            </Button>
          </div>
        </div>
      </Popover>

      {/* Desktop Quick Shortcuts & Capture Popover */}
      <Popover
        open={desktopMenuOpen}
        onOpenChange={setDesktopMenuOpen}
        anchorEl={desktopBtnRef.current}
        placement="bottom-end"
        className="w-[300px] p-3.5"
      >
        <div className="flex flex-col gap-3 text-[12px]">
          <div className="flex items-center justify-between">
            <span className="text-[12.5px] font-semibold text-[var(--text-primary)]">
              全局快捷键与采集
            </span>
            <button
              type="button"
              onClick={async () => {
                setDesktopMenuOpen(false);
                try {
                  const count = await getTransport().collectClipboardNow();
                  pushToast({
                    message: count > 0 ? `已采集 ${count} 项剪贴板内容` : '剪贴板暂无可采集内容',
                    tone: 'info',
                  });
                } catch (err) {
                  pushToast({
                    message: err instanceof Error && err.message ? err.message : '采集剪贴板失败',
                    tone: 'error',
                  });
                }
              }}
              className="charkle-pressable inline-flex items-center gap-1 px-2 py-1 rounded-[var(--radius-chip)] bg-[var(--accent-soft)] text-[var(--accent)] font-medium cursor-pointer"
            >
              <Clipboard size={12} />
              采集剪贴板
            </button>
          </div>

          {desktopStatus && (
            <>
              <SwitchToggle
                label="启用全局快捷键"
                checked={desktopStatus.hotkeys.enabled}
                onChange={async (checked) => {
                  try {
                    const updated = await getTransport().updateHotkeys({
                      ...desktopStatus.hotkeys,
                      enabled: checked,
                    });
                    setDesktopStatus({ ...desktopStatus, hotkeys: updated });
                  } catch (err) {
                    pushToast({
                      message: err instanceof Error && err.message ? err.message : '更新全局快捷键失败',
                      tone: 'error',
                    });
                  }
                }}
              />

              <div className="p-2 rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] flex flex-col gap-1.5 text-[11.5px] text-[var(--text-secondary)]">
                <div className="flex items-center justify-between">
                  <span>区域截图采集</span>
                  <kbd className="px-1.5 py-0.5 rounded-[var(--radius-card-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[10.5px]">
                    {desktopStatus.hotkeys.captureArea}
                  </kbd>
                </div>
                <div className="flex items-center justify-between">
                  <span>顶部悬浮窗</span>
                  <kbd className="px-1.5 py-0.5 rounded-[var(--radius-card-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[10.5px]">
                    {desktopStatus.hotkeys.toggleShelf}
                  </kbd>
                </div>
                <div className="flex items-center justify-between">
                  <span>剪贴板快速采集</span>
                  <kbd className="px-1.5 py-0.5 rounded-[var(--radius-card-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[10.5px]">
                    {desktopStatus.hotkeys.collectClipboard}
                  </kbd>
                </div>
              </div>

              <SwitchToggle
                label="随系统开机启动"
                checked={desktopStatus.autostartEnabled}
                onChange={async (checked) => {
                  try {
                    const enabled = await getTransport().setAutostartEnabled(checked);
                    setDesktopStatus({ ...desktopStatus, autostartEnabled: enabled });
                  } catch (err) {
                    pushToast({
                      message: err instanceof Error && err.message ? err.message : '更新开机启动设置失败',
                      tone: 'error',
                    });
                  }
                }}
              />

              <div className="pt-2 border-t border-[var(--border-hairline)] flex flex-col gap-1 text-[11px] text-[var(--text-tertiary)]">
                <div className="flex items-center justify-between">
                  <span>离线文字识别</span>
                  <span className="text-[var(--text-secondary)]">
                    {desktopStatus.ocr.selectedLanguage ?? '未安装语言包'}
                  </span>
                </div>
                {desktopStatus.ocr.diagnosticMessage && (
                  <p className="text-[11px] text-[var(--warning)] leading-relaxed">
                    {desktopStatus.ocr.diagnosticMessage}
                  </p>
                )}
                <div className="flex items-center justify-between">
                  <span>快捷唤起协议</span>
                  <span className="text-[var(--text-secondary)] charkle-mono">
                    {desktopStatus.deepLinkScheme}://
                  </span>
                </div>
              </div>
            </>
          )}
        </div>
      </Popover>
    </header>
  );
};
