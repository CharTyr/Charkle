import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowDownload16Regular,
  ArrowSync16Regular,
  Checkmark16Filled,
  ChevronDown12Regular,
  ChevronDown16Regular,
  ChevronUp16Regular,
  Cursor16Regular,
  Delete16Regular,
  Dismiss12Regular,
  FolderArrowRight16Regular,
  Home16Regular,
  Person16Regular,
  Search16Regular,
  SelectObject16Regular,
  SignOut20Regular,
  Sparkle20Filled,
  Target16Regular,
  Warning16Regular,
  ZoomIn16Regular,
  ZoomOut16Regular,
} from '@fluentui/react-icons';
import { isTauriRuntime } from '../../api/transport';
import { Button, Tooltip } from '../../design-system';
import { useLibraryStore } from '../../stores/libraryStore';
import { usePinterestStore } from '../../stores/pinterestStore';
import {
  buildFolderTree,
  flattenFolderTree,
  resolveSocialMediaUrl,
  type PinterestFeedSource,
} from '../../types/domain';
import { PinterestBoardImportModal } from './PinterestBoardImportModal';
import { PinterestInfiniteCanvas } from './PinterestInfiniteCanvas';
import { PinterestPinDetailModal } from './PinterestPinDetailModal';
import {
  SPATIAL_CAMERA_DEFAULT_SCALE,
  pinAspectRatio,
  pinDisplayImageUrl,
  pinDisplayTitle,
} from './spatialLayout';

function stopCanvasPropagation(e: React.SyntheticEvent): void {
  e.stopPropagation();
}

function sourceDisplayLabel(source: PinterestFeedSource): string {
  switch (source.kind) {
    case 'home':
      return '主页推荐';
    case 'search':
      return `搜索：${source.query}`;
    case 'board':
      return `画板：${source.board.name}`;
    case 'similar':
      return `相似：${pinDisplayTitle(source.seedPin)}`;
  }
}

export const PinterestWorkspace: React.FC = () => {
  const sessionState = usePinterestStore((s) => s.sessionState);
  const account = usePinterestStore((s) => s.account);
  const boards = usePinterestStore((s) => s.boards);
  const isLoadingBoards = usePinterestStore((s) => s.isLoadingBoards);
  const needsReauth = usePinterestStore((s) => s.needsReauth);
  const activeSource = usePinterestStore((s) => s.activeSource);
  const searchQueryDraft = usePinterestStore((s) => s.searchQueryDraft);
  const cards = usePinterestStore((s) => s.cards);
  const isLoadingFeed = usePinterestStore((s) => s.isLoadingFeed);
  const feedError = usePinterestStore((s) => s.feedError);

  const collectedPins = usePinterestStore((s) => s.collectedPins);
  const traySelectedPinIds = usePinterestStore((s) => s.traySelectedPinIds);
  const isTrayExpanded = usePinterestStore((s) => s.isTrayExpanded);
  const isQuickCollectMode = usePinterestStore((s) => s.isQuickCollectMode);
  const isImportingTray = usePinterestStore((s) => s.isImportingTray);
  const trayImportProgress = usePinterestStore((s) => s.trayImportProgress);

  const bootstrap = usePinterestStore((s) => s.bootstrap);
  const openLoginWindow = usePinterestStore((s) => s.openLoginWindow);
  const handleAuthChangedEvent = usePinterestStore((s) => s.handleAuthChangedEvent);
  const signOut = usePinterestStore((s) => s.signOut);
  const refreshBoards = usePinterestStore((s) => s.refreshBoards);
  const setSearchQueryDraft = usePinterestStore((s) => s.setSearchQueryDraft);
  const loadSource = usePinterestStore((s) => s.loadSource);
  const submitSearch = usePinterestStore((s) => s.submitSearch);
  const setQuickCollectMode = usePinterestStore((s) => s.setQuickCollectMode);
  const setTrayExpanded = usePinterestStore((s) => s.setTrayExpanded);
  const setTrayPinSelected = usePinterestStore((s) => s.setTrayPinSelected);
  const selectAllTrayPins = usePinterestStore((s) => s.selectAllTrayPins);
  const deselectAllTrayPins = usePinterestStore((s) => s.deselectAllTrayPins);
  const removeFromTray = usePinterestStore((s) => s.removeFromTray);
  const removeSelectedFromTray = usePinterestStore((s) => s.removeSelectedFromTray);
  const clearTray = usePinterestStore((s) => s.clearTray);
  const importTrayPins = usePinterestStore((s) => s.importTrayPins);
  const openPinDetail = usePinterestStore((s) => s.openPinDetail);
  const openBoardImportModal = usePinterestStore((s) => s.openBoardImportModal);

  const folders = useLibraryStore((s) => s.folders);
  const flatFolders = useMemo(() => flattenFolderTree(buildFolderTree(folders)), [folders]);

  const [cameraScale, setCameraScale] = useState(SPATIAL_CAMERA_DEFAULT_SCALE);
  const [sourceMenuOpen, setSourceMenuOpen] = useState(false);
  const [accountMenuOpen, setAccountMenuOpen] = useState(false);
  const [trayTargetFolderId, setTrayTargetFolderId] = useState<string>('');
  const [trayExtraTagsText, setTrayExtraTagsText] = useState('');

  const zoomCommandRef = useRef<{
    zoomBy: (factor: number) => void;
    resetCenter: () => void;
  } | null>(null);

  const isTauri = isTauriRuntime();

  useEffect(() => {
    void bootstrap();
  }, [bootstrap]);

  // Close floating menus when clicking outside
  useEffect(() => {
    if (!sourceMenuOpen && !accountMenuOpen) return;
    const handleClick = () => {
      setSourceMenuOpen(false);
      setAccountMenuOpen(false);
    };
    window.addEventListener('click', handleClick);
    return () => window.removeEventListener('click', handleClick);
  }, [sourceMenuOpen, accountMenuOpen]);

  const selectedTrayCount = useMemo(
    () => collectedPins.filter((p) => Boolean(traySelectedPinIds[p.id])).length,
    [collectedPins, traySelectedPinIds],
  );
  const allTraySelected = collectedPins.length > 0 && selectedTrayCount === collectedPins.length;

  const parseExtraTags = () =>
    trayExtraTagsText
      .split(/[,，\n]/)
      .map((s) => s.trim())
      .filter(Boolean);

  const handleTrayImport = async (onlySelected: boolean) => {
    const folderId = trayTargetFolderId.trim() || null;
    await importTrayPins(folderId, parseExtraTags(), onlySelected);
  };

  // Signed-out / checking welcome stage
  if (sessionState !== 'signedIn') {
    const checking = sessionState === 'unknown' || sessionState === 'checking';
    return (
      <div
        data-testid="pinterest-workspace"
        className="relative flex-1 min-w-0 min-h-0 h-full flex items-center justify-center p-6 overflow-auto"
      >
        <div className="w-full max-w-[460px] rounded-[18px] bg-[var(--bg-elevated)] border border-[var(--win-stroke-card)] shadow-[0_16px_48px_rgba(0,0,0,0.14)] p-7 flex flex-col items-center text-center gap-4">
          <div className="w-12 h-12 rounded-[14px] bg-[var(--accent-soft)] text-[var(--accent)] inline-flex items-center justify-center">
            <Sparkle20Filled className="w-6 h-6" />
          </div>

          <div className="flex flex-col gap-1.5">
            <h1 className="text-[18px] font-semibold text-[var(--text-primary)] tracking-[-0.01em]">
              Pinterest 无限灵感空间
            </h1>
            <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed">
              使用原生安全浏览器登录你的 Pinterest 账号，在 2D 无限空间中自由平移缩放浏览推荐、搜索与个人画板，并通过浮动托盘批量采集高清原图或一键导入整个画板收藏。
            </p>
          </div>

          {feedError && (
            <div className="w-full px-3 py-2 rounded-[10px] bg-[var(--danger-soft)] text-[12px] text-[var(--danger)] text-left">
              {feedError}
            </div>
          )}

          <div className="w-full flex flex-col gap-2 pt-1">
            <Button
              variant="accent"
              size="md"
              disabled={checking}
              data-testid="pinterest-signin-btn"
              onClick={() => void openLoginWindow()}
              className="w-full justify-center"
            >
              {checking ? '正在检查登录状态…' : '登录 Pinterest 账号'}
            </Button>

            <Button
              variant="subtle"
              size="sm"
              disabled={checking}
              onClick={() => void handleAuthChangedEvent(true)}
              className="w-full justify-center"
            >
              <ArrowSync16Regular className={`w-3.5 h-3.5 ${checking ? 'animate-spin' : ''}`} />
              <span>已完成登录，立即刷新</span>
            </Button>
          </div>

          <p className="text-[11.5px] text-[var(--text-tertiary)] leading-relaxed">
            支持账号密码及 Google / Apple OAuth 登录；登录会话仅持久保存在本机应用隔离目录中。
          </p>
        </div>
      </div>
    );
  }

  const accountLabel = account?.fullName?.trim() || (account?.username ? `@${account.username}` : 'Pinterest');

  return (
    <div
      data-testid="pinterest-workspace"
      className="relative flex-1 min-w-0 min-h-0 h-full overflow-hidden bg-[var(--bg-gallery)]"
    >
      {/* Full-bleed 2D Infinite Spatial Canvas */}
      <PinterestInfiniteCanvas
        onCameraScaleChange={setCameraScale}
        zoomCommandRef={zoomCommandRef}
      />

      {/* Empty / Loading / Error center state over canvas */}
      {isLoadingFeed && cards.length === 0 && (
        <div
          onPointerDown={stopCanvasPropagation}
          className="pointer-events-none absolute inset-0 flex items-center justify-center"
        >
          <div className="px-4 py-2.5 rounded-full bg-[var(--bg-elevated)]/92 border border-[var(--win-stroke-card)] shadow-lg backdrop-blur-md text-[13px] text-[var(--text-secondary)]">
            正在铺展 Pinterest 无限灵感空间…
          </div>
        </div>
      )}

      {!isLoadingFeed && cards.length === 0 && (
        <div
          onPointerDown={stopCanvasPropagation}
          className="absolute inset-0 flex items-center justify-center pointer-events-none"
        >
          <div className="pointer-events-auto max-w-[380px] p-5 rounded-[14px] bg-[var(--bg-elevated)]/95 border border-[var(--win-stroke-card)] shadow-lg backdrop-blur-md text-center flex flex-col items-center gap-3">
            <div className="text-[13.5px] font-medium text-[var(--text-primary)]">
              {feedError || '当前灵感流暂无可展示内容'}
            </div>
            <div className="flex items-center gap-2">
              <Button
                variant="accent"
                size="sm"
                onClick={() => void loadSource(activeSource)}
              >
                重新加载
              </Button>
              {needsReauth && (
                <Button variant="standard" size="sm" onClick={() => void openLoginWindow()}>
                  重新登录
                </Button>
              )}
            </div>
          </div>
        </div>
      )}

      {/* Top Floating Fluent Acrylic Toolbar */}
      <div
        data-testid="pinterest-top-toolbar"
        onPointerDown={stopCanvasPropagation}
        onMouseDown={stopCanvasPropagation}
        onWheel={stopCanvasPropagation}
        onClick={stopCanvasPropagation}
        className="absolute top-3 left-3 right-3 z-20 flex flex-wrap items-center justify-between gap-2 pointer-events-none"
      >
        {/* Left cluster: Feed/Board switcher + Search bar */}
        <div className="pointer-events-auto flex items-center gap-1.5 p-1 rounded-[12px] bg-[var(--bg-elevated)]/88 border border-[var(--win-stroke-card)] shadow-[0_8px_28px_rgba(0,0,0,0.14)] backdrop-blur-xl max-w-full">
          {/* Feed / Boards Menu */}
          <div className="relative">
            <button
              type="button"
              data-testid="pinterest-source-menu-btn"
              onClick={(e) => {
                e.stopPropagation();
                setAccountMenuOpen(false);
                setSourceMenuOpen((v) => !v);
              }}
              className="charkle-pressable h-8 px-2.5 rounded-[8px] inline-flex items-center gap-1.5 text-[12.5px] font-medium text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer max-w-[200px]"
            >
              <Home16Regular className="w-4 h-4 text-[var(--accent)] shrink-0" />
              <span className="truncate">{sourceDisplayLabel(activeSource)}</span>
              <ChevronDown12Regular className="w-3 h-3 text-[var(--text-tertiary)] shrink-0" />
            </button>

            {sourceMenuOpen && (
              <div
                onClick={stopCanvasPropagation}
                className="absolute left-0 top-10 w-[260px] max-h-[360px] overflow-y-auto rounded-[12px] bg-[var(--bg-elevated)] border border-[var(--win-stroke-card)] shadow-[0_14px_38px_rgba(0,0,0,0.24)] p-1.5 flex flex-col gap-0.5 z-30"
              >
                <button
                  type="button"
                  onClick={() => {
                    setSourceMenuOpen(false);
                    void loadSource({ kind: 'home' });
                  }}
                  className={[
                    'w-full px-2.5 py-1.5 rounded-[8px] text-left text-[12.5px] flex items-center gap-2 cursor-pointer',
                    activeSource.kind === 'home'
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                      : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)]',
                  ].join(' ')}
                >
                  <Home16Regular className="w-4 h-4 shrink-0" />
                  <span>主页推荐</span>
                </button>

                <div className="my-1 h-px bg-[var(--win-stroke-divider)]" />

                <div className="px-2.5 py-1 flex items-center justify-between text-[11px] font-semibold text-[var(--text-tertiary)]">
                  <span>我的画板 ({boards.length})</span>
                  <button
                    type="button"
                    onClick={() => void refreshBoards()}
                    className="text-[var(--text-secondary)] hover:text-[var(--accent)] cursor-pointer"
                  >
                    {isLoadingBoards ? '加载中…' : '刷新'}
                  </button>
                </div>

                {boards.length === 0 ? (
                  <div className="px-2.5 py-2 text-[12px] text-[var(--text-tertiary)]">
                    暂无画板
                  </div>
                ) : (
                  boards.map((board) => {
                    const active = activeSource.kind === 'board' && activeSource.board.id === board.id;
                    return (
                      <button
                        key={board.id}
                        type="button"
                        onClick={() => {
                          setSourceMenuOpen(false);
                          void loadSource({ kind: 'board', board });
                        }}
                        className={[
                          'w-full px-2.5 py-1.5 rounded-[8px] text-left text-[12.5px] flex items-center justify-between gap-2 cursor-pointer',
                          active
                            ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                            : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)]',
                        ].join(' ')}
                      >
                        <span className="truncate">{board.name}</span>
                        <span className="text-[11px] text-[var(--text-tertiary)] charkle-tabular shrink-0">
                          {board.pinCount}
                        </span>
                      </button>
                    );
                  })
                )}
              </div>
            )}
          </div>

          <div className="w-px h-4 bg-[var(--win-stroke-divider)]" />

          {/* Search box */}
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void submitSearch();
            }}
            className="h-8 px-2 flex items-center gap-1.5 rounded-[8px] bg-[var(--bg-subtle)]/75 focus-within:ring-1 focus-within:ring-[var(--accent)] w-[200px] sm:w-[250px]"
          >
            <Search16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)] shrink-0" />
            <input
              type="text"
              value={searchQueryDraft}
              onChange={(e) => setSearchQueryDraft(e.target.value)}
              placeholder="搜索 Pinterest 灵感…"
              aria-label="搜索 Pinterest 灵感"
              className="flex-1 min-w-0 bg-transparent text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
            />
            {searchQueryDraft && (
              <button
                type="button"
                aria-label="清除搜索"
                onClick={() => {
                  setSearchQueryDraft('');
                  if (activeSource.kind === 'search') {
                    void loadSource({ kind: 'home' });
                  }
                }}
                className="w-4 h-4 rounded-full inline-flex items-center justify-center text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer"
              >
                <Dismiss12Regular className="w-3 h-3" />
              </button>
            )}
          </form>
        </div>

        {/* Right cluster: Batch Board Import + Zoom Controls + Account Menu */}
        <div className="pointer-events-auto flex items-center gap-1.5 p-1 rounded-[12px] bg-[var(--bg-elevated)]/88 border border-[var(--win-stroke-card)] shadow-[0_8px_28px_rgba(0,0,0,0.14)] backdrop-blur-xl">
          <Button
            variant="subtle"
            size="xs"
            data-testid="pinterest-open-board-import-btn"
            onClick={openBoardImportModal}
          >
            <FolderArrowRight16Regular className="w-3.5 h-3.5 text-[var(--accent)]" />
            <span>导入画板收藏</span>
          </Button>

          <div className="w-px h-4 bg-[var(--win-stroke-divider)]" />

          {/* Zoom Controls */}
          <div className="flex items-center gap-0.5">
            <Tooltip content="缩小画布" side="bottom">
              <button
                type="button"
                aria-label="缩小画布"
                onClick={() => zoomCommandRef.current?.zoomBy(0.84)}
                className="w-7 h-7 rounded-[7px] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
              >
                <ZoomOut16Regular className="w-4 h-4" />
              </button>
            </Tooltip>
            <span className="min-w-[40px] text-center text-[11.5px] font-medium text-[var(--text-secondary)] charkle-tabular">
              {Math.round(cameraScale * 100)}%
            </span>
            <Tooltip content="放大画布" side="bottom">
              <button
                type="button"
                aria-label="放大画布"
                onClick={() => zoomCommandRef.current?.zoomBy(1.19)}
                className="w-7 h-7 rounded-[7px] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
              >
                <ZoomIn16Regular className="w-4 h-4" />
              </button>
            </Tooltip>
            <Tooltip content="回到画布中心" side="bottom">
              <button
                type="button"
                aria-label="回到画布中心"
                onClick={() => zoomCommandRef.current?.resetCenter()}
                className="w-7 h-7 rounded-[7px] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
              >
                <Target16Regular className="w-4 h-4" />
              </button>
            </Tooltip>
          </div>

          <div className="w-px h-4 bg-[var(--win-stroke-divider)]" />

          {/* Account Menu */}
          <div className="relative">
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation();
                setSourceMenuOpen(false);
                setAccountMenuOpen((v) => !v);
              }}
              className="h-7 px-2 rounded-[7px] inline-flex items-center gap-1.5 text-[12px] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer max-w-[150px]"
            >
              <Person16Regular className="w-3.5 h-3.5 text-[var(--text-secondary)] shrink-0" />
              <span className="truncate">{accountLabel}</span>
            </button>

            {accountMenuOpen && (
              <div
                onClick={stopCanvasPropagation}
                className="absolute right-0 top-9 w-[200px] rounded-[12px] bg-[var(--bg-elevated)] border border-[var(--win-stroke-card)] shadow-[0_14px_38px_rgba(0,0,0,0.24)] p-1.5 flex flex-col gap-0.5 z-30"
              >
                <div className="px-2.5 py-1.5 text-[11.5px] text-[var(--text-tertiary)] truncate">
                  {account?.username ? `@${account.username}` : accountLabel}
                </div>
                <button
                  type="button"
                  onClick={() => {
                    setAccountMenuOpen(false);
                    void loadSource(activeSource);
                  }}
                  className="w-full px-2.5 py-1.5 rounded-[8px] text-left text-[12.5px] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] flex items-center gap-2 cursor-pointer"
                >
                  <ArrowSync16Regular className="w-3.5 h-3.5" />
                  <span>刷新当前灵感流</span>
                </button>
                <button
                  type="button"
                  onClick={() => {
                    setAccountMenuOpen(false);
                    void openLoginWindow();
                  }}
                  className="w-full px-2.5 py-1.5 rounded-[8px] text-left text-[12.5px] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] flex items-center gap-2 cursor-pointer"
                >
                  <Person16Regular className="w-3.5 h-3.5" />
                  <span>重新登录 / 切换账号</span>
                </button>
                <div className="my-1 h-px bg-[var(--win-stroke-divider)]" />
                <button
                  type="button"
                  onClick={() => {
                    setAccountMenuOpen(false);
                    void signOut();
                  }}
                  className="w-full px-2.5 py-1.5 rounded-[8px] text-left text-[12.5px] text-[var(--danger)] hover:bg-[var(--danger-soft)] flex items-center gap-2 cursor-pointer"
                >
                  <SignOut20Regular className="w-3.5 h-3.5" />
                  <span>退出 Pinterest</span>
                </button>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Session expired warning strip */}
      {needsReauth && (
        <div
          onPointerDown={stopCanvasPropagation}
          onClick={stopCanvasPropagation}
          className="absolute top-[60px] left-1/2 -translate-x-1/2 z-20 px-3.5 py-2 rounded-full bg-[var(--bg-elevated)] border border-[var(--warning)]/40 shadow-lg flex items-center gap-2.5 text-[12.5px]"
        >
          <Warning16Regular className="w-4 h-4 text-[var(--warning)]" />
          <span className="text-[var(--text-primary)]">Pinterest 登录状态已失效</span>
          <Button variant="accent" size="xs" onClick={() => void openLoginWindow()}>
            重新登录
          </Button>
        </div>
      )}

      {/* Bottom-Left Floating Icon-Only Browse / Fast-Pick Mode Capsule */}
      <div
        data-testid="pinterest-mode-toggle"
        onPointerDown={stopCanvasPropagation}
        onMouseDown={stopCanvasPropagation}
        onWheel={stopCanvasPropagation}
        onClick={stopCanvasPropagation}
        className="absolute bottom-4 left-4 z-20 p-1 rounded-full bg-[var(--bg-elevated)]/90 border border-[var(--win-stroke-card)] shadow-[0_8px_28px_rgba(0,0,0,0.18)] backdrop-blur-xl flex items-center gap-1"
      >
        <Tooltip content="浏览模式（点击卡片查看高清详情与类似素材）" side="top">
          <button
            type="button"
            data-testid="pinterest-mode-browse"
            aria-label="浏览模式"
            aria-pressed={!isQuickCollectMode}
            onClick={() => setQuickCollectMode(false)}
            className={[
              'w-8 h-8 rounded-full inline-flex items-center justify-center transition-colors cursor-pointer',
              !isQuickCollectMode
                ? 'bg-[var(--accent)] text-[var(--accent-text)] shadow-sm'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)]',
            ].join(' ')}
          >
            <Cursor16Regular className="w-4 h-4" />
          </button>
        </Tooltip>

        <Tooltip content="快选模式（单击卡片直接加入/移出收藏托盘）" side="top">
          <button
            type="button"
            data-testid="pinterest-mode-fastpick"
            aria-label="快选模式"
            aria-pressed={isQuickCollectMode}
            onClick={() => setQuickCollectMode(true)}
            className={[
              'w-8 h-8 rounded-full inline-flex items-center justify-center transition-colors cursor-pointer',
              isQuickCollectMode
                ? 'bg-[var(--accent)] text-[var(--accent-text)] shadow-sm'
                : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)]',
            ].join(' ')}
          >
            <SelectObject16Regular className="w-4 h-4" />
          </button>
        </Tooltip>
      </div>

      {/* Bottom-Right Persistent Shopping-Cart Collection Tray */}
      {collectedPins.length > 0 && (
        <div
          data-testid="pinterest-collection-tray"
          onPointerDown={stopCanvasPropagation}
          onMouseDown={stopCanvasPropagation}
          onWheel={stopCanvasPropagation}
          onClick={stopCanvasPropagation}
          className="absolute bottom-4 right-4 z-20 max-w-[min(860px,calc(100%-96px))]"
        >
          {!isTrayExpanded ? (
            /* Collapsed Tray Capsule */
            <div className="flex items-center gap-2.5 pl-2.5 pr-2 py-1.5 rounded-full bg-[var(--bg-elevated)]/92 border border-[var(--win-stroke-card)] shadow-[0_12px_36px_rgba(0,0,0,0.22)] backdrop-blur-xl">
              <button
                type="button"
                data-testid="pinterest-tray-expand-btn"
                onClick={() => setTrayExpanded(true)}
                className="flex items-center gap-2.5 cursor-pointer group"
              >
                {/* 4 stacked preview thumbnails */}
                <div className="flex items-center -space-x-2">
                  {collectedPins.slice(0, 4).map((pin) => {
                    const thumb = resolveSocialMediaUrl(
                      pinDisplayImageUrl(pin, 140),
                      isTauri,
                    );
                    return (
                      <div
                        key={pin.id}
                        className="w-8 h-8 rounded-[8px] overflow-hidden ring-2 ring-[var(--bg-elevated)] bg-[var(--bg-subtle)] shrink-0"
                      >
                        {thumb && (
                          <img
                            src={thumb}
                            alt={pinDisplayTitle(pin)}
                            className="w-full h-full object-cover"
                          />
                        )}
                      </div>
                    );
                  })}
                </div>
                <div className="flex items-center gap-1.5 text-[12.5px] font-medium text-[var(--text-primary)]">
                  <span>收藏托盘</span>
                  <span className="px-1.5 py-0.5 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11px] font-semibold charkle-tabular">
                    {collectedPins.length}
                  </span>
                  <ChevronUp16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)] group-hover:text-[var(--text-primary)]" />
                </div>
              </button>

              <Button
                variant="accent"
                size="xs"
                disabled={isImportingTray}
                data-testid="pinterest-tray-quick-import-btn"
                onClick={() => void handleTrayImport(false)}
              >
                <ArrowDownload16Regular className="w-3.5 h-3.5" />
                <span>
                  {isImportingTray && trayImportProgress
                    ? `入库 ${trayImportProgress.completed}/${trayImportProgress.total}`
                    : '批量入库'}
                </span>
              </Button>
            </div>
          ) : (
            /* Expanded Horizontal Aspect-Preserving Waterfall Drawer */
            <div
              data-testid="pinterest-tray-drawer"
              className="w-[min(840px,calc(100vw-120px))] rounded-[16px] bg-[var(--bg-elevated)]/96 border border-[var(--win-stroke-card)] shadow-[0_20px_54px_rgba(0,0,0,0.3)] backdrop-blur-xl overflow-hidden flex flex-col"
            >
              {/* Drawer Header */}
              <div className="px-4 py-2.5 border-b border-[var(--win-stroke-divider)] flex items-center justify-between gap-2">
                <div className="flex items-center gap-2 text-[13px] font-semibold text-[var(--text-primary)]">
                  <span>收藏托盘</span>
                  <span className="px-1.5 py-0.5 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11px] charkle-tabular">
                    {collectedPins.length} 项
                  </span>
                  {selectedTrayCount > 0 && (
                    <span className="text-[11.5px] font-normal text-[var(--text-secondary)]">
                      已选 {selectedTrayCount} 项
                    </span>
                  )}
                </div>

                <div className="flex items-center gap-1.5">
                  <Button
                    variant="subtle"
                    size="xs"
                    onClick={() => (allTraySelected ? deselectAllTrayPins() : selectAllTrayPins())}
                  >
                    {allTraySelected ? '取消全选' : '全选'}
                  </Button>
                  <Button
                    variant="subtle"
                    size="xs"
                    disabled={selectedTrayCount === 0}
                    data-testid="pinterest-tray-remove-selected-btn"
                    onClick={removeSelectedFromTray}
                  >
                    <Delete16Regular className="w-3.5 h-3.5" />
                    <span>移除已选</span>
                  </Button>
                  <Button variant="subtle" size="xs" onClick={clearTray}>
                    清空
                  </Button>
                  <button
                    type="button"
                    aria-label="收起收藏托盘"
                    onClick={() => setTrayExpanded(false)}
                    className="w-7 h-7 rounded-[7px] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                  >
                    <ChevronDown16Regular className="w-4 h-4" />
                  </button>
                </div>
              </div>

              {/* Horizontal Aspect-Preserving Waterfall Strip (height = 146px, proportional width 76..260px) */}
              <div className="px-4 py-3 overflow-x-auto flex items-center gap-2.5">
                {collectedPins.map((pin) => {
                  const ratio = pinAspectRatio(pin);
                  const cardHeight = 146;
                  const cardWidth = Math.min(260, Math.max(76, Math.round(cardHeight * ratio)));
                  const selected = Boolean(traySelectedPinIds[pin.id]);
                  const imgUrl = resolveSocialMediaUrl(pinDisplayImageUrl(pin, cardWidth * 1.4), isTauri);
                  const title = pinDisplayTitle(pin);

                  return (
                    <div
                      key={pin.id}
                      data-testid={`pinterest-tray-card-${pin.id}`}
                      style={{
                        width: cardWidth,
                        height: cardHeight,
                        backgroundColor: pin.dominantColorHex || 'var(--bg-subtle)',
                      }}
                      className={[
                        'group relative shrink-0 rounded-[10px] overflow-hidden shadow-sm transition-all',
                        selected
                          ? 'ring-2 ring-[var(--accent)]'
                          : 'ring-1 ring-black/10 dark:ring-white/10 opacity-85 hover:opacity-100',
                      ].join(' ')}
                    >
                      {/* Click card artwork -> opens floating Pin detail overlay */}
                      <button
                        type="button"
                        data-testid={`pinterest-tray-open-detail-${pin.id}`}
                        aria-label={`查看 ${title} 详情`}
                        onClick={() => void openPinDetail(pin, true)}
                        className="w-full h-full block cursor-pointer"
                      >
                        {imgUrl && (
                          <img
                            src={imgUrl}
                            alt={title}
                            loading="lazy"
                            className="w-full h-full object-cover block"
                          />
                        )}
                      </button>

                      {/* Top-left subset selection checkbox */}
                      <button
                        type="button"
                        data-testid={`pinterest-tray-select-${pin.id}`}
                        aria-label={selected ? '取消选中' : '选中此项'}
                        aria-pressed={selected}
                        onClick={(e) => {
                          e.stopPropagation();
                          setTrayPinSelected(pin.id, !selected);
                        }}
                        className={[
                          'absolute top-1.5 left-1.5 w-5 h-5 rounded-[6px] inline-flex items-center justify-center shadow cursor-pointer transition-colors',
                          selected
                            ? 'bg-[var(--accent)] text-[var(--accent-text)]'
                            : 'bg-black/55 text-white/80 hover:bg-black/75',
                        ].join(' ')}
                      >
                        {selected && <Checkmark16Filled className="w-3.5 h-3.5" />}
                      </button>

                      {/* Top-right single remove */}
                      <button
                        type="button"
                        aria-label="从托盘移除"
                        onClick={(e) => {
                          e.stopPropagation();
                          removeFromTray(pin.id);
                        }}
                        className="absolute top-1.5 right-1.5 w-5 h-5 rounded-full bg-black/58 text-white inline-flex items-center justify-center opacity-0 group-hover:opacity-100 hover:bg-[var(--danger)] transition-opacity cursor-pointer"
                      >
                        <Dismiss12Regular className="w-3 h-3" />
                      </button>
                    </div>
                  );
                })}
              </div>

              {/* Drawer Footer: Target Folder + Extra Tags + Batch Import */}
              <div className="px-4 py-2.5 border-t border-[var(--win-stroke-divider)] bg-[var(--bg-subtle)]/40 flex flex-wrap items-center gap-2">
                <select
                  aria-label="目标文件夹"
                  value={trayTargetFolderId}
                  disabled={isImportingTray}
                  onChange={(e) => setTrayTargetFolderId(e.target.value)}
                  className="h-8 px-2.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] border border-[var(--win-stroke-control)] text-[12px] text-[var(--text-primary)] outline-none min-w-[140px]"
                >
                  <option value="">放入收件箱</option>
                  {flatFolders.map((node) => (
                    <option key={node.folder.id} value={node.folder.id}>
                      {'　'.repeat(node.depth)}
                      {node.folder.name}
                    </option>
                  ))}
                </select>

                <input
                  type="text"
                  value={trayExtraTagsText}
                  disabled={isImportingTray}
                  onChange={(e) => setTrayExtraTagsText(e.target.value)}
                  placeholder="附加标签（逗号分隔）"
                  className="h-8 flex-1 min-w-[140px] px-2.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] border border-[var(--win-stroke-control)] text-[12px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none focus:border-[var(--accent)]"
                />

                <Button
                  variant="accent"
                  size="sm"
                  disabled={isImportingTray || (selectedTrayCount === 0 && collectedPins.length === 0)}
                  data-testid="pinterest-tray-batch-import-btn"
                  onClick={() => void handleTrayImport(selectedTrayCount > 0)}
                >
                  <ArrowDownload16Regular className="w-3.5 h-3.5" />
                  <span>
                    {isImportingTray && trayImportProgress
                      ? `正在入库 ${trayImportProgress.completed}/${trayImportProgress.total}…`
                      : selectedTrayCount > 0 && selectedTrayCount < collectedPins.length
                        ? `入库已选 (${selectedTrayCount})`
                        : `批量入库 (${collectedPins.length})`}
                  </span>
                </Button>
              </div>
            </div>
          )}
        </div>
      )}

      {/* Floating Pin Detail Overlay + Similar Pins + Lightbox */}
      <PinterestPinDetailModal />

      {/* Batch Board Collection Importer Modal */}
      <PinterestBoardImportModal />
    </div>
  );
};
