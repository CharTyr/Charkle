import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Cloud,
  Copy,
  Minus,
  Monitor,
  Moon,
  PanelLeft,
  PanelRight,
  Plus,
  RefreshCw,
  Search,
  Square,
  Sun,
  X,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import { CharkleBrandMark, type ThemeMode } from '../../design-system';
import { useCoordinatorStore, useSyncAIStore } from '../../stores';

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

/**
 * Custom 38px frameless Windows titlebar with Win11 Snap Layout `HTMAXBUTTON` rect sync
 * and Mica / SolidFallback continuity.
 */
export const Titlebar: React.FC = () => {
  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const setThemeMode = useCoordinatorStore((s) => s.setThemeMode);
  const sidebarOpen = useCoordinatorStore((s) => s.sidebarOpen);
  const toggleSidebar = useCoordinatorStore((s) => s.toggleSidebar);
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const toggleInspector = useCoordinatorStore((s) => s.toggleInspector);
  const setJumpOpen = useCoordinatorStore((s) => s.setJumpOpen);
  const setCaptureOpen = useCoordinatorStore((s) => s.setCaptureOpen);

  const syncStatus = useSyncAIStore((s) => s.syncStatus);
  const syncing = useSyncAIStore((s) => s.syncing);
  const syncNow = useSyncAIStore((s) => s.syncNow);

  const maxBtnRef = useRef<HTMLButtonElement | null>(null);
  const [isMaximized, setIsMaximized] = useState(false);

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
    const el = maxBtnRef.current;
    let observer: ResizeObserver | null = null;
    if (el && typeof ResizeObserver !== 'undefined') {
      observer = new ResizeObserver(reportMaximizeRect);
      observer.observe(el);
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

  const handleToggleMaximize = async () => {
    try {
      const next = await getTransport().windowToggleMaximize();
      setIsMaximized(next);
      requestAnimationFrame(reportMaximizeRect);
    } catch {
      // Ignored in non-window preview
    }
  };

  const syncBusy =
    syncing ||
    (syncStatus != null &&
      syncStatus.phase !== 'idle' &&
      !(typeof syncStatus.phase === 'object' && 'error' in syncStatus.phase));
  const syncError =
    syncStatus != null && typeof syncStatus.phase === 'object' && 'error' in syncStatus.phase;

  return (
    <header
      data-tauri-drag-region
      onDoubleClick={(e) => {
        if ((e.target as HTMLElement).closest('button, input')) return;
        void handleToggleMaximize();
      }}
      className="charkle-sidebar-surface h-[38px] shrink-0 flex items-center justify-between pl-2.5 pr-0 border-b border-[var(--border-hairline)] select-none z-40"
    >
      {/* Left: Brand mark + Navigation controls */}
      <div className="flex items-center gap-1.5 min-w-0">
        <div
          data-tauri-drag-region
          className="flex items-center gap-2 pr-1.5 cursor-default"
        >
          <CharkleBrandMark size={18} />
          <span className="text-[12.5px] font-semibold tracking-[-0.01em] text-[var(--text-primary)]">
            Charkle
          </span>
        </div>

        <button
          type="button"
          onClick={toggleSidebar}
          aria-label={sidebarOpen ? '隐藏侧边栏' : '显示侧边栏'}
          title={sidebarOpen ? '隐藏侧边栏 (Ctrl+\\)' : '显示侧边栏 (Ctrl+\\)'}
          className={[
            'charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--radius-chip)] cursor-pointer',
            sidebarOpen
              ? 'text-[var(--text-primary)] bg-[var(--bg-subtle)]/80'
              : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
          ].join(' ')}
        >
          <PanelLeft size={15} />
        </button>

        <button
          type="button"
          onClick={() => setCaptureOpen(true)}
          aria-label="导入或采集素材"
          title="导入素材或采集链接 (Ctrl+N)"
          className="charkle-pressable h-7 px-2 inline-flex items-center gap-1 rounded-[var(--radius-chip)] text-[12px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
        >
          <Plus size={14} />
          <span className="hidden sm:inline">采集</span>
        </button>
      </div>

      {/* Center: Quick Jump Ctrl+J trigger */}
      <div className="flex-1 flex items-center justify-center px-3 min-w-0" data-tauri-drag-region>
        <button
          type="button"
          onClick={() => setJumpOpen(true)}
          aria-label="快速跳转"
          className="charkle-pressable h-[26px] w-full max-w-[300px] px-2.5 inline-flex items-center justify-between gap-2 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)]/75 hover:bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-secondary)] cursor-pointer"
        >
          <span className="inline-flex items-center gap-1.5 min-w-0 truncate">
            <Search size={12.5} className="shrink-0 text-[var(--text-tertiary)]" />
            <span className="truncate">快速跳转文件夹、标签或素材…</span>
          </span>
          <kbd className="text-[10.5px] px-1.5 py-0.5 rounded-[5px] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-tertiary)] shrink-0">
            Ctrl+J
          </kbd>
        </button>
      </div>

      {/* Right: Sync + Theme + Inspector + Windows Native Caption Controls */}
      <div className="flex items-center h-full">
        <div className="flex items-center gap-1 pr-2">
          <button
            type="button"
            onClick={() => void syncNow()}
            disabled={syncBusy}
            title={syncError ? '同步出错，点击重试' : '立即同步素材库'}
            aria-label="同步状态"
            className={[
              'charkle-pressable h-7 px-2 inline-flex items-center gap-1.5 rounded-[var(--radius-chip)] text-[11.5px] cursor-pointer',
              syncError
                ? 'text-[var(--danger)] bg-[var(--danger-soft)]'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
            ].join(' ')}
          >
            {syncBusy ? (
              <RefreshCw size={13.5} className="animate-spin text-[var(--accent)]" />
            ) : (
              <Cloud size={13.5} />
            )}
            <span className="hidden md:inline charkle-tabular">
              {syncBusy
                ? '同步中'
                : syncError
                  ? '同步异常'
                  : syncStatus?.pendingOpCount
                    ? `待同步 ${syncStatus.pendingOpCount}`
                    : '本地就绪'}
            </span>
          </button>

          <button
            type="button"
            onClick={() => void setThemeMode(NEXT_THEME[themeMode])}
            title={`切换外观（当前：${THEME_LABEL[themeMode]}）`}
            aria-label={THEME_LABEL[themeMode]}
            className="charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--radius-chip)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            {themeMode === 'light' && <Sun size={14.5} />}
            {themeMode === 'dark' && <Moon size={14.5} />}
            {themeMode === 'system' && <Monitor size={14.5} />}
          </button>

          <button
            type="button"
            onClick={toggleInspector}
            aria-label={inspectorOpen ? '隐藏检查器' : '显示检查器'}
            title={inspectorOpen ? '隐藏右侧检查器 (Ctrl+I)' : '显示右侧检查器 (Ctrl+I)'}
            className={[
              'charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--radius-chip)] cursor-pointer',
              inspectorOpen
                ? 'text-[var(--text-primary)] bg-[var(--bg-subtle)]/80'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
            ].join(' ')}
          >
            <PanelRight size={15} />
          </button>
        </div>

        {/* Native Windows caption buttons (46px wide each per Win11 HIG) */}
        <div className="flex items-stretch h-full">
          <button
            type="button"
            aria-label="最小化"
            onClick={() => void getTransport().windowMinimize()}
            className="w-[44px] h-full inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)] cursor-pointer transition-colors duration-100"
          >
            <Minus size={14} />
          </button>

          <button
            ref={maxBtnRef}
            type="button"
            aria-label={isMaximized ? '还原窗口' : '最大化'}
            onClick={() => void handleToggleMaximize()}
            className="w-[44px] h-full inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)] cursor-pointer transition-colors duration-100"
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
    </header>
  );
};
