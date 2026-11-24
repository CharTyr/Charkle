import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowLeft16Regular,
  ChevronRight12Regular,
  Desktop20Regular,
  Dismiss16Regular,
  Maximize16Regular,
  PanelLeftExpand20Regular,
  PanelRight20Filled,
  PanelRight20Regular,
  Screenshot20Regular,
  SquareMultiple16Regular,
  Subtract16Regular,
  WeatherMoon20Regular,
  WeatherSunny20Regular,
  WindowHeaderHorizontal20Filled,
  WindowHeaderHorizontal20Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import { CharkleFolderIcon, Tooltip, type ThemeMode } from '../../design-system';
import {
  getFolderBreadcrumbs,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';

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
 * Slim 40px right-column-only transparent drag titlebar over Mica Alt:
 * - Left slot: folder breadcrumb trail, moodboard back + title, or clean drag region
 * - Right slot: 4 Fluent utility buttons (Region Capture, Top Drop Shelf, Theme Cycle, Inspector Toggle)
 *   + native 46x40px Win11 caption controls with HTMAXBUTTON Snap Layouts rect sync
 */
export const Titlebar: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const setDestination = useCoordinatorStore((s) => s.setDestination);
  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const setThemeMode = useCoordinatorStore((s) => s.setThemeMode);
  const sidebarOpen = useCoordinatorStore((s) => s.sidebarOpen);
  const sidebarCollapsed = useCoordinatorStore((s) => s.sidebarCollapsed);
  const setSidebarOpen = useCoordinatorStore((s) => s.setSidebarOpen);
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const toggleInspector = useCoordinatorStore((s) => s.toggleInspector);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const folders = useLibraryStore((s) => s.folders);
  const boards = useMoodboardStore((s) => s.boards);
  const activeBoard = useMoodboardStore((s) => s.activeBoard);

  const headerRef = useRef<HTMLElement | null>(null);
  const maxBtnRef = useRef<HTMLButtonElement | null>(null);
  const [isMaximized, setIsMaximized] = useState(false);
  const [startingCapture, setStartingCapture] = useState(false);
  const [shelfExpanded, setShelfExpanded] = useState(false);
  const [togglingShelf, setTogglingShelf] = useState(false);

  const folderBreadcrumbs = useMemo(() => {
    if (destination.type !== 'folder') return [];
    return getFolderBreadcrumbs(folders, destination.id);
  }, [destination, folders]);

  const activeMoodboardTitle = useMemo(() => {
    if (destination.type !== 'moodboard') return null;
    if (activeBoard?.id === destination.id) return activeBoard.title;
    return boards.find((b) => b.id === destination.id)?.title ?? '情绪板';
  }, [destination, activeBoard, boards]);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;
    const transport = getTransport();

    void transport
      .getDesktopIntegrationStatus()
      .then((status) => {
        if (!disposed) {
          setShelfExpanded(Boolean(status.shelfVisible));
        }
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

  const utilBtnClass = (active = false) =>
    [
      'charkle-pressable h-[30px] w-[30px] shrink-0 inline-flex items-center justify-center rounded-[var(--win-radius-control)] cursor-pointer disabled:opacity-50',
      'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
      active
        ? 'text-[var(--accent)] bg-[var(--win-subtle-active)]'
        : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)]',
    ].join(' ');

  return (
    <header
      ref={headerRef}
      data-tauri-drag-region
      onDoubleClick={(e) => {
        if ((e.target as HTMLElement).closest('button, input, [data-tauri-drag-region="false"]')) {
          return;
        }
        void handleToggleMaximize();
      }}
      className="charkle-mica-titlebar h-[40px] shrink-0 flex items-center justify-between pl-3 pr-0 bg-transparent select-none z-40"
    >
      {/* Left slot: Lightweight context breadcrumb / moodboard back + title / clean drag area */}
      <div
        data-tauri-drag-region
        className="flex-1 min-w-0 h-full flex items-center gap-1.5 pr-3 overflow-hidden"
      >
        {!sidebarOpen && (
          <Tooltip content="显示侧边栏" shortcut="Ctrl+\" side="bottom">
            <button
              type="button"
              data-tauri-drag-region="false"
              onClick={() => setSidebarOpen(true)}
              aria-label="显示侧边栏"
              className={utilBtnClass(false)}
            >
              <PanelLeftExpand20Regular className="w-4 h-4" />
            </button>
          </Tooltip>
        )}

        {destination.type === 'folder' && folderBreadcrumbs.length > 0 && (
          <nav
            aria-label="文件夹路径"
            data-tauri-drag-region="false"
            className="flex items-center gap-1 min-w-0 overflow-hidden"
          >
            {folderBreadcrumbs.map((crumb, idx) => {
              const isLast = idx === folderBreadcrumbs.length - 1;
              return (
                <React.Fragment key={crumb.id}>
                  {idx > 0 && (
                    <ChevronRight12Regular className="w-3 h-3 text-[var(--text-tertiary)] shrink-0" />
                  )}
                  {isLast ? (
                    <span className="inline-flex items-center gap-1.5 px-1.5 py-0.5 text-[12.5px] font-medium text-[var(--text-primary)] min-w-0 truncate">
                      <CharkleFolderIcon
                        colorHex={crumb.colorHex}
                        customSymbol={crumb.customSymbol}
                        size={14}
                        isActive
                      />
                      <span className="truncate">{crumb.name}</span>
                    </span>
                  ) : (
                    <button
                      type="button"
                      data-tauri-drag-region="false"
                      onClick={() => setDestination({ type: 'folder', id: crumb.id })}
                      className="charkle-pressable px-1.5 py-0.5 rounded-[var(--win-radius-control)] text-[12.5px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] truncate max-w-[160px] cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
                    >
                      {crumb.name}
                    </button>
                  )}
                </React.Fragment>
              );
            })}
          </nav>
        )}

        {destination.type === 'moodboard' && activeMoodboardTitle && (
          <div
            data-tauri-drag-region="false"
            className="flex items-center gap-1 min-w-0 overflow-hidden"
          >
            <Tooltip content="返回所有情绪板" side="bottom">
              <button
                type="button"
                data-tauri-drag-region="false"
                aria-label="返回所有情绪板"
                onClick={() => setDestination({ type: 'moodboardsHome' })}
                className="charkle-pressable h-7 px-2 inline-flex items-center gap-1 rounded-[var(--win-radius-control)] text-[12.5px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] shrink-0 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]"
              >
                <ArrowLeft16Regular className="w-3.5 h-3.5 shrink-0" />
                <span>情绪板</span>
              </button>
            </Tooltip>
            <ChevronRight12Regular className="w-3 h-3 text-[var(--text-tertiary)] shrink-0" />
            <span className="text-[12.5px] font-medium text-[var(--text-primary)] truncate">
              {activeMoodboardTitle}
            </span>
          </div>
        )}
      </div>

      {/* Right slot: 4 Fluent Utility Buttons + Native 46x40px Win11 Caption Controls */}
      <div data-tauri-drag-region="false" className="flex items-center h-full shrink-0">
        <div data-tauri-drag-region="false" className="flex items-center gap-0.5 pr-1.5 shrink-0">
          <Tooltip content="区域截图采集" shortcut="Alt+Shift+A" side="bottom">
            <button
              type="button"
              data-tauri-drag-region="false"
              disabled={startingCapture}
              onClick={() => void handleStartRegionCapture()}
              aria-label="区域截图采集"
              className={utilBtnClass(false)}
            >
              <Screenshot20Regular className="w-4 h-4" />
            </button>
          </Tooltip>

          <Tooltip content="显示 / 隐藏顶部悬浮窗" shortcut="Alt+Shift+S" side="bottom">
            <button
              type="button"
              data-tauri-drag-region="false"
              disabled={togglingShelf}
              aria-pressed={shelfExpanded}
              onClick={() => void handleToggleShelf()}
              aria-label="切换顶部悬浮窗"
              className={utilBtnClass(shelfExpanded)}
            >
              {shelfExpanded ? (
                <WindowHeaderHorizontal20Filled className="w-4 h-4" />
              ) : (
                <WindowHeaderHorizontal20Regular className="w-4 h-4" />
              )}
            </button>
          </Tooltip>

          <Tooltip content={`切换外观（当前：${THEME_LABEL[themeMode]}）`} side="bottom">
            <button
              type="button"
              data-tauri-drag-region="false"
              onClick={() => void setThemeMode(NEXT_THEME[themeMode])}
              aria-label={THEME_LABEL[themeMode]}
              className={utilBtnClass(false)}
            >
              {themeMode === 'light' && <WeatherSunny20Regular className="w-4 h-4" />}
              {themeMode === 'dark' && <WeatherMoon20Regular className="w-4 h-4" />}
              {themeMode === 'system' && <Desktop20Regular className="w-4 h-4" />}
            </button>
          </Tooltip>

          <Tooltip
            content={inspectorOpen ? '隐藏右侧检查器' : '显示右侧检查器'}
            shortcut="Ctrl+I"
            side="bottom"
          >
            <button
              type="button"
              data-tauri-drag-region="false"
              aria-pressed={inspectorOpen}
              onClick={toggleInspector}
              aria-label={inspectorOpen ? '隐藏检查器' : '显示检查器'}
              className={utilBtnClass(inspectorOpen)}
            >
              {inspectorOpen ? (
                <PanelRight20Filled className="w-4 h-4" />
              ) : (
                <PanelRight20Regular className="w-4 h-4" />
              )}
            </button>
          </Tooltip>
        </div>

        {/* Native 46x40px Win11 Caption Controls (with HTMAXBUTTON Snap Layouts rect sync) */}
        <div className="flex items-stretch h-full">
          <button
            type="button"
            aria-label="最小化"
            onClick={() => void getTransport().windowMinimize()}
            className="w-[46px] h-[40px] inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] hover:text-[var(--text-primary)] cursor-pointer transition-colors duration-[83ms]"
          >
            <Subtract16Regular className="w-3.5 h-3.5" />
          </button>

          <button
            ref={maxBtnRef}
            type="button"
            aria-label={isMaximized ? '还原窗口' : '最大化'}
            onClick={() => void handleToggleMaximize()}
            className="w-[46px] h-[40px] inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] hover:text-[var(--text-primary)] cursor-pointer transition-colors duration-[83ms]"
          >
            {isMaximized ? (
              <SquareMultiple16Regular className="w-3.5 h-3.5" />
            ) : (
              <Maximize16Regular className="w-3.5 h-3.5" />
            )}
          </button>

          <button
            type="button"
            aria-label="关闭窗口"
            onClick={() => void getTransport().windowClose()}
            className="w-[46px] h-[40px] inline-flex items-center justify-center text-[var(--text-secondary)] hover:bg-[#C42B1C] active:bg-[#B22719] hover:text-white cursor-pointer transition-colors duration-[83ms]"
          >
            <Dismiss16Regular className="w-3.5 h-3.5" />
          </button>
        </div>
      </div>
    </header>
  );
};
