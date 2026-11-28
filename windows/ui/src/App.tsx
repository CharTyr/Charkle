import React, { useEffect, useState } from 'react';
import { getTransport, isTauriRuntime } from './api/transport';
import { Button, ModalShell, ToastHost } from './design-system';
import { ErrorBoundary } from './design-system/ErrorBoundary';
import { QuickCaptureModal } from './features/capture/QuickCaptureModal';
import { PaneResizeDivider } from './features/chrome/PaneResizeDivider';
import { Titlebar } from './features/chrome/Titlebar';
import { WindowResizeEdges } from './features/chrome/WindowResizeEdges';
import { SmartDeduplicationModal } from './features/dedup/SmartDeduplicationModal';
import {
  PointerDragGhostLayer,
  registerPointerDragHandlers,
} from './features/dnd/PointerDragContext';
import { useTauriFileDrop } from './features/dnd/useTauriFileDrop';
import { GalleryView } from './features/gallery/GalleryView';
import { runMaterialPackageImport } from './features/import/materialPackageImport';
import { InspectorView } from './features/inspector/InspectorView';
import { JumpAnywhereModal } from './features/jump/JumpAnywhereModal';
import { MoodboardGeneratorModal } from './features/moodboard/MoodboardGeneratorModal';
import { MoodboardsHome } from './features/moodboard/MoodboardsHome';
import { OnboardingStudio } from './features/onboarding/OnboardingStudio';
import { PinterestWorkspace } from './features/pinterest/PinterestWorkspace';
import { QuickLookOverlay } from './features/quicklook/QuickLookOverlay';
import { SettingsOverlay } from './features/settings/SettingsOverlay';
import { SidebarView } from './features/sidebar/SidebarView';
import { AppUpdateModal } from './features/updates/AppUpdateModal';
import {
  DEFAULT_INSPECTOR_WIDTH,
  DEFAULT_SIDEBAR_WIDTH,
  MAX_INSPECTOR_WIDTH,
  MAX_SIDEBAR_WIDTH,
  MIN_INSPECTOR_WIDTH,
  MIN_SIDEBAR_WIDTH,
  clampInspectorWidth,
  clampSidebarWidth,
  isPlainWebBookmark,
  resolveEffectivePaneWidths,
  type QuickLookOriginRect,
  useAppUpdateStore,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  usePinterestStore,
  useSyncAIStore,
} from './stores';
import { buildFolderTree, flattenFolderTree } from './types/domain';

function findAssetCardOriginRect(assetId: string): QuickLookOriginRect | null {
  if (typeof document === 'undefined') return null;
  const escaped =
    typeof CSS !== 'undefined' && typeof CSS.escape === 'function'
      ? CSS.escape(assetId)
      : assetId.replace(/"/g, '\\"');
  const cardEl =
    document.querySelector(`[data-asset-card-id="${escaped}"]`) ??
    document.querySelector(`[data-asset-id="${escaped}"]`);
  const rect = cardEl?.getBoundingClientRect();
  if (!rect || rect.width <= 0 || rect.height <= 0) return null;
  return {
    left: rect.left,
    top: rect.top,
    width: rect.width,
    height: rect.height,
  };
}

function isTypingTarget(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null;
  if (!el) return false;
  const tag = el.tagName;
  return (
    tag === 'INPUT' ||
    tag === 'TEXTAREA' ||
    tag === 'SELECT' ||
    el.isContentEditable
  );
}

function formatBookmarkDomain(asset: {
  sourceDomain?: string | null;
  sourceURL?: string | null;
}): string {
  if (asset.sourceDomain?.trim()) {
    return asset.sourceDomain.trim().replace(/^www\./i, '');
  }
  if (asset.sourceURL) {
    try {
      return new URL(asset.sourceURL).host.toLowerCase().replace(/^www\./, '');
    } catch {
      // Fallback below
    }
  }
  return '网页';
}

const URL_WRAPPER_PAIRS: ReadonlyArray<readonly [string, string]> = [
  ['<', '>'],
  ['"', '"'],
  ["'", "'"],
  ['(', ')'],
  ['[', ']'],
  ['「', '」'],
  ['《', '》'],
  ['“', '”'],
];

const URL_TRAILING_STOP_CHARS = new Set([
  '.',
  ',',
  ';',
  '!',
  '?',
  '。',
  '，',
  '；',
  '！',
  '？',
  '、',
  '”',
  '’',
  '）',
  '】',
  '」',
  '》',
  '>',
  '"',
]);

const URL_LEADING_STOP_CHARS = new Set(['<', '"', "'", '「', '《', '“', '‘']);

function stripUrlWrappersAndPunctuation(input: string): string {
  let s = input.trim();
  let changed = true;
  while (changed && s.length > 0) {
    changed = false;
    while (s.length >= 2) {
      let unwrapped = false;
      for (const [open, close] of URL_WRAPPER_PAIRS) {
        if (s.startsWith(open) && s.endsWith(close)) {
          s = s.slice(open.length, s.length - close.length).trim();
          unwrapped = true;
          changed = true;
          break;
        }
      }
      if (!unwrapped) break;
    }

    while (s.length > 0) {
      const last = s[s.length - 1];
      if (URL_TRAILING_STOP_CHARS.has(last)) {
        s = s.slice(0, -1);
        changed = true;
      } else if (last === ')') {
        const openCount = (s.match(/\(/g) ?? []).length;
        const closeCount = (s.match(/\)/g) ?? []).length;
        if (closeCount > openCount) {
          s = s.slice(0, -1);
          changed = true;
        } else {
          break;
        }
      } else if (last === ']') {
        const openCount = (s.match(/\[/g) ?? []).length;
        const closeCount = (s.match(/\]/g) ?? []).length;
        if (closeCount > openCount) {
          s = s.slice(0, -1);
          changed = true;
        } else {
          break;
        }
      } else {
        break;
      }
    }

    while (s.length > 0 && URL_LEADING_STOP_CHARS.has(s[0])) {
      s = s.slice(1);
      changed = true;
    }
  }
  return s;
}

function parseStandaloneWebUrl(raw: string): string | null {
  const cleaned = stripUrlWrappersAndPunctuation(raw);
  if (!cleaned || /\s/.test(cleaned)) return null;

  const lower = cleaned.toLowerCase();
  let normalized: string;
  if (lower.startsWith('http://')) {
    normalized = `http://${cleaned.slice(7)}`;
  } else if (lower.startsWith('https://')) {
    normalized = `https://${cleaned.slice(8)}`;
  } else if (lower.startsWith('www.')) {
    const remainder = cleaned.slice(4);
    if (!remainder.includes('.') || remainder.startsWith('.')) return null;
    normalized = `https://${cleaned}`;
  } else if (
    lower.startsWith('xiaohongshu.com/') ||
    lower.startsWith('m.xiaohongshu.com/') ||
    lower.startsWith('xhslink.com/') ||
    lower.startsWith('douyin.com/') ||
    lower.startsWith('m.douyin.com/') ||
    lower.startsWith('v.douyin.com/') ||
    lower.startsWith('iesdouyin.com/')
  ) {
    normalized = `https://${cleaned}`;
  } else {
    return null;
  }

  try {
    const parsed = new URL(normalized);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
    if (parsed.username || parsed.password) return null;
    const host = parsed.hostname.toLowerCase();
    if (!host) return null;
    if (host !== 'localhost' && !host.includes(':')) {
      const parts = host.split('.');
      if (parts.length < 2 || parts.some((p) => p.length === 0)) return null;
    }
    return parsed.toString();
  } catch {
    return null;
  }
}

/**
 * Matches macOS `WebURLParser.extractWebURL`: supports standalone URLs (case-insensitive scheme,
 * `www.`, Xiaohongshu / `xhslink.com` share copy, Unicode paths, balanced parens) and short share
 * copy (`<= 320` chars & `<= 5` lines) while preserving long prose and bare filenames as text.
 */
export function extractWebUrlFromPaste(text: string): string | null {
  const trimmed = text.trim();
  if (!trimmed) return null;

  const direct = parseStandaloneWebUrl(trimmed);
  if (direct) return direct;

  const lineCount = trimmed.split(/\r\n|\r|\n/).length;

  // Recognize Xiaohongshu & Douyin web/mobile share copy (including `xhslink.com` & `v.douyin.com` short links)
  if (trimmed.length <= 800 && lineCount <= 12) {
    const shareMatches = trimmed.match(
      /(?:https?:\/\/)?(?:(?:www|m|v)\.)?(?:xiaohongshu\.com\/(?:explore|discovery\/item|user\/profile)\/[^\s\u3000"'<>（）【】「」《》“”]+|xhslink\.com\/[^\s\u3000"'<>（）【】「」《》“”]+|douyin\.com\/(?:video|note|user|share)\/[^\s\u3000"'<>（）【】「」《》“”]+|douyin\.com\/[^\s\u3000"'<>（）【】「」《》“”]*modal_id=\d+[^\s\u3000"'<>（）【】「」《》“”]*|iesdouyin\.com\/share\/[^\s\u3000"'<>（）【】「」《》“”]+|v\.douyin\.com\/[^\s\u3000"'<>（）【】「」《》“”]+)/gi,
    );
    if (shareMatches) {
      for (const candidate of shareMatches) {
        const parsed = parseStandaloneWebUrl(candidate);
        if (parsed) return parsed;
      }
    }
  }

  if (trimmed.length > 320 || lineCount > 5) return null;

  const matches = trimmed.match(/(?:https?:\/\/|www\.)[^\s\u3000]+/gi);
  if (!matches) return null;
  for (const candidate of matches) {
    const parsed = parseStandaloneWebUrl(candidate);
    if (parsed) return parsed;
  }
  return null;
}

export const App: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const sidebarOpen = useCoordinatorStore((s) => s.sidebarOpen);
  const sidebarCollapsed = useCoordinatorStore((s) => s.sidebarCollapsed);
  const sidebarWidth = useCoordinatorStore((s) => s.sidebarWidth);
  const setSidebarCollapsed = useCoordinatorStore((s) => s.setSidebarCollapsed);
  const setSidebarWidth = useCoordinatorStore((s) => s.setSidebarWidth);
  const commitSidebarWidth = useCoordinatorStore((s) => s.commitSidebarWidth);
  const resetSidebarWidth = useCoordinatorStore((s) => s.resetSidebarWidth);
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const inspectorWidth = useCoordinatorStore((s) => s.inspectorWidth);
  const setInspectorWidth = useCoordinatorStore((s) => s.setInspectorWidth);
  const commitInspectorWidth = useCoordinatorStore((s) => s.commitInspectorWidth);
  const resetInspectorWidth = useCoordinatorStore((s) => s.resetInspectorWidth);
  const isResizingPane = useCoordinatorStore((s) => s.isResizingPane);
  const setResizingPane = useCoordinatorStore((s) => s.setResizingPane);
  const moodboardGeneratorOpen = useCoordinatorStore((s) => s.moodboardGeneratorOpen);
  const setMoodboardGeneratorOpen = useCoordinatorStore((s) => s.setMoodboardGeneratorOpen);
  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const syncWindowChrome = useCoordinatorStore((s) => s.syncWindowChrome);

  const [windowWidth, setWindowWidth] = useState<number>(() =>
    typeof window !== 'undefined' && window.innerWidth > 0 ? window.innerWidth : 1360,
  );

  const bootstrap = useLibraryStore((s) => s.bootstrap);
  const refreshAll = useLibraryStore((s) => s.refreshAll);
  const patchSingleAssetInMemory = useLibraryStore((s) => s.patchSingleAssetInMemory);

  const fetchBoards = useMoodboardStore((s) => s.fetchBoards);
  const openBoard = useMoodboardStore((s) => s.openBoard);
  const pushAgentStep = useMoodboardStore((s) => s.pushAgentStep);
  const refreshSyncAndCache = useSyncAIStore((s) => s.refreshSyncAndCache);
  const setSyncStatus = useSyncAIStore((s) => s.setSyncStatus);

  const [pendingTrashDeleteIds, setPendingTrashDeleteIds] = useState<string[]>([]);

  // Window-level native OS file/folder drop router (Gallery, Sidebar Folders, Inbox, Moodboards & Canvas)
  useTauriFileDrop({
    onDropFiles: async (paths, target, pos) => {
      const coord = useCoordinatorStore.getState();
      const lib = useLibraryStore.getState();
      const mb = useMoodboardStore.getState();
      const transport = getTransport();

      if (target?.kind === 'moodboardCanvas' && mb.activeBoard) {
        try {
          const created = await transport.ingestFiles(paths, null, null);
          void lib.refreshAll(coord.destination);
          if (created.length > 0) {
            window.dispatchEvent(
              new CustomEvent('charkle:canvas-file-drop', {
                detail: {
                  assetIds: created.map((a) => a.id),
                  clientX: pos.clientX,
                  clientY: pos.clientY,
                },
              }),
            );
            coord.pushToast({
              message: `已导入并上板 ${created.length} 项素材`,
              tone: 'success',
            });
          }
        } catch (err) {
          coord.pushToast({
            message: `拖入失败：${err instanceof Error ? err.message : String(err)}`,
            tone: 'error',
          });
        }
        return;
      }

      if (target?.kind === 'board') {
        try {
          const created = await transport.ingestFiles(paths, null, target.id);
          await mb.fetchBoards();
          if (mb.activeBoard?.id === target.id) {
            await mb.openBoard(target.id);
          }
          await lib.refreshAll(coord.destination);
          coord.pushToast({
            message: `已导入 ${created.length} 项到情绪板「${target.label ?? '情绪板'}」`,
            tone: 'success',
          });
        } catch (err) {
          coord.pushToast({
            message: `导入情绪板失败：${err instanceof Error ? err.message : String(err)}`,
            tone: 'error',
          });
        }
        return;
      }

      const targetFolderId =
        target?.kind === 'folder'
          ? target.id
          : target?.kind === 'inbox' || target?.kind === 'folderRoot'
            ? null
            : coord.destination.type === 'folder'
              ? coord.destination.id
              : null;

      await lib.ingestFiles(paths, targetFolderId, coord.destination);
    },
  });

  // Register global PointerDrag targets (Inbox, Trash, Moodboards)
  useEffect(() => {
    return registerPointerDragHandlers({
      onDropAssetsToInbox: (assetIds) => {
        const coord = useCoordinatorStore.getState();
        const lib = useLibraryStore.getState();
        const lookup = new Map<string, string | null>();
        for (const a of lib.allAssets) lookup.set(a.id, a.folderID ?? null);
        for (const a of lib.assets) lookup.set(a.id, a.folderID ?? null);

        // Group assets by their previous folder so Undo restores every item cleanly
        const byPrevFolder = new Map<string, string[]>();
        for (const id of assetIds) {
          const prev = lookup.get(id) ?? null;
          if (prev) {
            const list = byPrevFolder.get(prev) ?? [];
            list.push(id);
            byPrevFolder.set(prev, list);
          }
        }

        const prevFolderEntries = [...byPrevFolder.entries()];
        if (prevFolderEntries.length === 1 && prevFolderEntries[0][1].length === assetIds.length) {
          const [prevFolderId] = prevFolderEntries[0];
          void lib.updateAssets(
            { assetIDs: assetIds, folderAssignment: 'inbox' },
            coord.destination,
            {
              undoMessage: `已移动 ${assetIds.length} 项至收件箱`,
              undoPatch: { assetIDs: assetIds, folderAssignment: { folder: prevFolderId } },
            },
          );
          return;
        }

        void lib
          .updateAssets({ assetIDs: assetIds, folderAssignment: 'inbox' }, coord.destination)
          .then(() => {
            coord.pushToast({
              message: `已移动 ${assetIds.length} 项至收件箱`,
              tone: 'info',
              actionLabel: prevFolderEntries.length > 0 ? '撤销' : undefined,
              onAction:
                prevFolderEntries.length > 0
                  ? () => {
                      const currentDest = useCoordinatorStore.getState().destination;
                      void Promise.all(
                        prevFolderEntries.map(([prevId, ids]) =>
                          useLibraryStore
                            .getState()
                            .updateAssets(
                              { assetIDs: ids, folderAssignment: { folder: prevId } },
                              currentDest,
                            ),
                        ),
                      );
                    }
                  : undefined,
            });
          });
      },
      onDropAssetsToTrash: (assetIds) => {
        const coord = useCoordinatorStore.getState();
        const lib = useLibraryStore.getState();
        coord.clearSelection();
        void lib.updateAssets(
          { assetIDs: assetIds, isTrashed: true },
          coord.destination,
          {
            undoMessage: `已将 ${assetIds.length} 项移入回收站`,
            undoPatch: { assetIDs: assetIds, isTrashed: false },
          },
        );
      },
      onDropAssetsToBoard: (boardId, assetIds) => {
        // addAssetsToBoard already reports success/error toasts cleanly
        void useMoodboardStore.getState().addAssetsToBoard(boardId, assetIds);
      },
    });
  }, []);

  // Initial bootstrap + window chrome sync + live desktop event bridge
  useEffect(() => {
    void syncWindowChrome();
    void bootstrap(useCoordinatorStore.getState().destination);
    void fetchBoards();
    void refreshSyncAndCache();

    // Auto-show skippable Onboarding Studio on first launch in desktop runtime
    if (isTauriRuntime() && !useCoordinatorStore.getState().onboardingDone) {
      useCoordinatorStore.getState().openOnboarding();
    }

    let disposed = false;
    let unlisten: (() => void) | null = null;
    void getTransport()
      .subscribeEvents({
        onSurfaceState: (surface) => {
          useCoordinatorStore.getState().applySurfaceState(surface);
        },
        onLibraryChanged: () => {
          useLibraryStore.getState().bumpMediaRevision();
          void refreshAll(useCoordinatorStore.getState().destination);
        },
        onSyncStatus: (status) => {
          const prevPhase = useSyncAIStore.getState().syncStatus?.phase;
          const wasSyncing =
            prevPhase !== undefined && prevPhase !== 'idle' && !(typeof prevPhase === 'object' && 'error' in prevPhase);
          setSyncStatus(status);
          if (wasSyncing && status.phase === 'idle') {
            useLibraryStore.getState().bumpMediaRevision();
            void refreshAll(useCoordinatorStore.getState().destination);
          }
        },
        onSyncProgressiveMetadata: ({ hasBoards }) => {
          void refreshAll(useCoordinatorStore.getState().destination);
          if (hasBoards) {
            void fetchBoards();
          }
        },
        onSyncProgressiveThumbnails: (assetIds) => {
          useLibraryStore.getState().bumpThumbnailRevisions(assetIds);
        },
        onAssetEnriched: (assetId) => {
          void getTransport()
            .fetchAsset(assetId)
            .then((asset) => {
              if (asset) patchSingleAssetInMemory(asset);
            })
            .catch(() => {});
        },
        onBoardUpdated: () => {
          void fetchBoards();
        },
        onClipboardCollected: (count) => {
          if (count > 0) {
            useCoordinatorStore.getState().pushToast({
              message: `已从系统剪贴板采集 ${count} 项灵感`,
              tone: 'success',
            });
          }
        },
        onExtensionImported: (payload) => {
          void refreshAll(useCoordinatorStore.getState().destination);
          if (payload.targetBoardId) {
            void fetchBoards();
          }
          const count = Math.max(1, payload.count || 1);
          useCoordinatorStore.getState().pushToast({
            message: `浏览器扩展已导入 ${count} 项素材`,
            tone: 'success',
          });
        },
        onMainOpenAsset: ({ assetId, openQuickLook }) => {
          const coord = useCoordinatorStore.getState();
          const lib = useLibraryStore.getState();
          const openTarget = (resolved: ReturnType<typeof lib.assets.find>) => {
            coord.setSelection([assetId], assetId);
            coord.requestGalleryReveal({ assetId });
            if (!openQuickLook) return;
            if (isPlainWebBookmark(resolved) && resolved?.sourceURL) {
              const domain = formatBookmarkDomain(resolved);
              void getTransport()
                .openExternalUrl(resolved.sourceURL)
                .then(() => {
                  coord.pushToast({
                    message: `已在默认浏览器中打开 ${domain}`,
                    tone: 'info',
                  });
                })
                .catch(() => {
                  coord.pushToast({ message: '无法在默认浏览器中打开链接', tone: 'error' });
                });
              void useLibraryStore.getState().markAssetOpened(resolved.id);
            } else {
              (document.activeElement as HTMLElement | null)?.blur?.();
              coord.openQuickLook(assetId, findAssetCardOriginRect(assetId));
            }
          };

          const existing =
            lib.assets.find((a) => a.id === assetId) ??
            lib.allAssets.find((a) => a.id === assetId);
          if (!existing) {
            coord.setDestination({ type: 'allItems' }, { preserveSelection: true });
            void lib.refreshAll({ type: 'allItems' }).then(() => {
              const latest = useLibraryStore.getState();
              const found =
                latest.assets.find((a) => a.id === assetId) ??
                latest.allAssets.find((a) => a.id === assetId);
              openTarget(found);
            });
          } else {
            openTarget(existing);
          }
        },
        onDeepLinkNavigate: (payload) => {
          const coord = useCoordinatorStore.getState();
          const lib = useLibraryStore.getState();
          if (payload.action === 'openAsset') {
            coord.setDestination({ type: 'allItems' }, { preserveSelection: true });
            coord.setSelection([payload.id], payload.id);
            coord.requestGalleryReveal({ assetId: payload.id });
            if (!lib.assets.some((a) => a.id === payload.id)) {
              void lib.refreshAll({ type: 'allItems' });
            }
          } else if (payload.action === 'openFolder') {
            coord.closeQuickLook();
            coord.setDestination({ type: 'folder', id: payload.id });
          } else if (payload.action === 'openBoard') {
            coord.closeQuickLook();
            coord.setDestination({ type: 'moodboard', id: payload.id });
            void openBoard(payload.id);
          }
        },
        onMoodboardAgentStep: (step) => {
          pushAgentStep(step);
        },
        onUpdateProgress: (progress) => {
          useAppUpdateStore.getState().handleProgressEvent(progress);
        },
        onUpdatePhase: (phase) => {
          useAppUpdateStore.getState().handlePhaseEvent(phase);
        },
        onMainCheckUpdates: () => {
          void useAppUpdateStore.getState().checkForUpdatesManually({ presentSheet: true });
        },
        onGDirectInstallProgress: (progress) => {
          useSyncAIStore.getState().setGDirectInstallProgress(progress);
        },
        onPinterestAuthChanged: (autoCloseLogin) => {
          void usePinterestStore.getState().handleAuthChangedEvent(autoCloseLogin);
        },
        onPinterestTrayImportProgress: (progress) => {
          usePinterestStore.getState().handleTrayImportProgressEvent(progress);
        },
        onPinterestBoardImportProgress: (progress) => {
          usePinterestStore.getState().handleBoardImportProgressEvent(progress);
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

    // Single deferred one-shot GitHub Releases check (4s delay, 6h throttle, zero idle timers).
    let cancelLaunchUpdateCheck: (() => void) | null = null;
    if (isTauriRuntime()) {
      cancelLaunchUpdateCheck = useAppUpdateStore
        .getState()
        .scheduleDeferredLaunchCheck((update) => {
          useCoordinatorStore.getState().pushToast({
            message: `发现新版本 v${update.version}`,
            tone: 'info',
            durationMs: 8000,
            actionLabel: '查看更新',
            onAction: () => useAppUpdateStore.getState().openSheet(),
          });
        }, 4000);
    }

    return () => {
      disposed = true;
      cancelLaunchUpdateCheck?.();
      unlisten?.();
    };
  }, [
    syncWindowChrome,
    bootstrap,
    fetchBoards,
    openBoard,
    refreshSyncAndCache,
    refreshAll,
    setSyncStatus,
    patchSingleAssetInMemory,
    pushAgentStep,
  ]);

  // React to OS light/dark theme flips when themeMode === 'system'
  useEffect(() => {
    if (themeMode !== 'system' || typeof window === 'undefined' || !window.matchMedia) {
      return;
    }
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const handler = () => void syncWindowChrome();
    mq.addEventListener?.('change', handler);
    return () => mq.removeEventListener?.('change', handler);
  }, [themeMode, syncWindowChrome]);

  // Refresh Win11 Mica & OS transparency state when returning from Windows Settings
  useEffect(() => {
    if (!isTauriRuntime() || typeof window === 'undefined') return;
    const handleFocus = () => void syncWindowChrome();
    window.addEventListener('focus', handleFocus);
    return () => window.removeEventListener('focus', handleFocus);
  }, [syncWindowChrome]);

  // Auto-collapse sidebar to 64px compact rail on narrow viewports (< 860px, Fluent 2 §3.2 #1)
  // without clobbering localStorage or fighting manual expand / Ctrl+F.
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const NARROW_SIDEBAR_BREAKPOINT = 860;
    const isNarrow = () =>
      window.innerWidth > 0 && window.innerWidth < NARROW_SIDEBAR_BREAKPOINT;

    let wasNarrow = isNarrow();
    let autoCollapsed = false;

    if (wasNarrow && !useCoordinatorStore.getState().sidebarCollapsed) {
      autoCollapsed = true;
      useCoordinatorStore.setState({ sidebarCollapsed: true });
    }

    const handleResize = () => {
      if (window.innerWidth > 0) {
        setWindowWidth(window.innerWidth);
      }
      const nowNarrow = isNarrow();
      if (!wasNarrow && nowNarrow) {
        if (!useCoordinatorStore.getState().sidebarCollapsed) {
          autoCollapsed = true;
          useCoordinatorStore.setState({ sidebarCollapsed: true });
        }
      } else if (wasNarrow && !nowNarrow) {
        if (autoCollapsed) {
          autoCollapsed = false;
          const userPrefCollapsed =
            typeof localStorage !== 'undefined' &&
            localStorage.getItem('charkle.win.sidebarCollapsed') === '1';
          if (!userPrefCollapsed && useCoordinatorStore.getState().sidebarCollapsed) {
            useCoordinatorStore.setState({ sidebarCollapsed: false });
          }
        }
      }
      wasNarrow = nowNarrow;
    };

    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  // Refresh assets whenever sidebar destination changes
  useEffect(() => {
    if (destination.type === 'moodboardsHome' || destination.type === 'moodboard') {
      void fetchBoards();
      return;
    }
    if (destination.type === 'pinterest') {
      return;
    }
    void refreshAll(destination);
  }, [destination, refreshAll, fetchBoards]);

  // Global keyboard shortcuts (masking strictly against Ctrl/Meta/Alt/Shift; never breaking on CapsLock/NumLock)
  useEffect(() => {
    const hasNonQuickLookModal = (): boolean =>
      Boolean(
        document.querySelector(
          '[role="dialog"][aria-modal="true"]:not([data-testid="quicklook-overlay"])',
        ),
      );

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.isComposing || e.keyCode === 229) return;

      const mod = e.ctrlKey || e.metaKey;
      const lowerKey = e.key.toLowerCase();
      const coord = useCoordinatorStore.getState();
      const lib = useLibraryStore.getState();
      const typing = isTypingTarget(e.target);
      const otherModalOpen =
        coord.captureOpen ||
        coord.onboardingOpen ||
        coord.moodboardGeneratorOpen ||
        coord.dedupOpen ||
        hasNonQuickLookModal();
      const anyBlockingModal =
        coord.jumpOpen || coord.settingsOpen || otherModalOpen;

      // Ctrl+, opens/closes centered 9-pane Settings Overlay (never opens on top of other modals)
      if (mod && !e.shiftKey && !e.altKey && e.key === ',') {
        if (coord.settingsOpen) {
          e.preventDefault();
          coord.closeSettings();
          return;
        }
        if (!otherModalOpen && !coord.jumpOpen) {
          e.preventDefault();
          coord.openSettings();
        }
        return;
      }

      // Ctrl+J / Ctrl+K toggles 0ms instant Jump Anywhere (works in main & Quick Look, never over other modals)
      if (mod && !e.shiftKey && !e.altKey && (lowerKey === 'j' || lowerKey === 'k')) {
        if (e.repeat) return;
        if (coord.jumpOpen) {
          e.preventDefault();
          coord.setJumpOpen(false);
          return;
        }
        if (!coord.settingsOpen && !otherModalOpen) {
          e.preventDefault();
          coord.setJumpOpen(true);
        }
        return;
      }

      // Ctrl+F expands & focuses the single global Sidebar search box (when not in a modal or Quick Look)
      if (mod && !e.shiftKey && !e.altKey && lowerKey === 'f') {
        if (!anyBlockingModal && !coord.quickLookAssetId) {
          e.preventDefault();
          coord.requestSidebarSearchFocus();
        }
        return;
      }

      // Ctrl+I / Ctrl+Alt+I toggles synced 300px Right Inspector (works in both Main & Quick Look, never over modals)
      if (mod && !e.shiftKey && lowerKey === 'i') {
        if (!anyBlockingModal && !typing) {
          e.preventDefault();
          coord.toggleInspector();
        }
        return;
      }

      // Ctrl+Shift+D opens/closes Smart Deduplication Modal
      if (mod && e.shiftKey && !e.altKey && lowerKey === 'd') {
        if (coord.dedupOpen) {
          if (!coord.quickLookAssetId) {
            e.preventDefault();
            coord.closeDeduplication();
          }
          return;
        }
        if (!anyBlockingModal && !typing && !coord.quickLookAssetId) {
          e.preventDefault();
          coord.openDeduplication();
        }
        return;
      }

      if (anyBlockingModal || typing) {
        return;
      }

      const hasPrimaryModifiers = e.ctrlKey || e.metaKey || e.altKey || e.shiftKey;
      const inMoodboard =
        coord.destination.type === 'moodboardsHome' ||
        coord.destination.type === 'moodboard' ||
        coord.destination.type === 'pinterest';

      // Suspend background workspace shortcuts while Quick Look is active
      if (coord.quickLookAssetId) return;

      if (mod && !e.shiftKey && !e.altKey && lowerKey === 'n') {
        e.preventDefault();
        coord.setCaptureOpen(true);
        return;
      }

      // Ctrl+Shift+I opens Material Package Importer (.eaglepack / .zip)
      if (mod && e.shiftKey && !e.altKey && lowerKey === 'i') {
        e.preventDefault();
        void runMaterialPackageImport('files');
        return;
      }

      // Ctrl+Shift+S toggles expandable Visual Filter Bar
      if (mod && e.shiftKey && !e.altKey && lowerKey === 's') {
        e.preventDefault();
        coord.toggleVisualFilterBar();
        return;
      }

      if (mod && !e.shiftKey && !e.altKey && e.key === '\\') {
        e.preventDefault();
        if (!coord.sidebarOpen) coord.setSidebarOpen(true);
        else coord.toggleSidebarCollapsed();
        return;
      }

      if (mod && !e.shiftKey && !e.altKey && e.key === '1') {
        e.preventDefault();
        coord.setLayoutMode('verticalMasonry');
        return;
      }
      if (mod && !e.shiftKey && !e.altKey && e.key === '2') {
        e.preventDefault();
        coord.setLayoutMode('horizontalJustified');
        return;
      }
      if (mod && !e.shiftKey && !e.altKey && e.key === '3') {
        e.preventDefault();
        coord.setLayoutMode('galleryFilmstrip');
        return;
      }
      if (mod && !e.shiftKey && !e.altKey && e.key === '4') {
        e.preventDefault();
        coord.setLayoutMode('ringGallery');
        return;
      }

      // Ctrl+X cuts selected assets so user can move them into another folder / Inbox via Ctrl+V
      if (mod && !e.shiftKey && !e.altKey && lowerKey === 'x') {
        const hasTextSel = Boolean(window.getSelection?.()?.toString().trim());
        if (!hasTextSel && coord.selectedAssetIds.length > 0 && !inMoodboard) {
          e.preventDefault();
          const ids = [...coord.selectedAssetIds];
          lib.cutAssets(ids);
          coord.pushToast({
            message: `已剪切 ${ids.length} 项，前往目标文件夹或收件箱按 Ctrl+V 移动`,
            tone: 'info',
          });
          return;
        }
      }

      // Ctrl+V pastes previously cut assets into current folder or Inbox
      if (mod && !e.shiftKey && !e.altKey && lowerKey === 'v') {
        if (
          lib.cutAssetIds.length > 0 &&
          !inMoodboard &&
          (coord.destination.type === 'folder' || coord.destination.type === 'inbox')
        ) {
          e.preventDefault();
          const targetFolderId =
            coord.destination.type === 'folder' ? coord.destination.id : null;
          void lib.pasteCutAssets(targetFolderId, coord.destination);
          return;
        }
      }

      // Ctrl+C copies selected asset files to system clipboard when no text is selected
      if (mod && !e.shiftKey && !e.altKey && lowerKey === 'c') {
        const hasTextSel = Boolean(window.getSelection?.()?.toString().trim());
        if (!hasTextSel && coord.selectedAssetIds.length > 0 && !inMoodboard) {
          e.preventDefault();
          const ids = [...coord.selectedAssetIds];
          void getTransport()
            .copyAssetsToClipboard(ids)
            .then((n) => {
              coord.pushToast({
                message: `已拷贝 ${n} 项素材文件到剪贴板`,
                tone: 'success',
              });
            })
            .catch((err) => {
              coord.pushToast({
                message: err instanceof Error ? err.message : '无法拷贝素材文件',
                tone: 'error',
              });
            });
          return;
        }
      }

      // Ctrl+A select all in gallery
      if (mod && !e.shiftKey && !e.altKey && lowerKey === 'a' && !inMoodboard) {
        e.preventDefault();
        coord.setSelection(lib.assets.map((a) => a.id));
        return;
      }

      // Escape clears selection (and cancels pending cut buffer if selection is already empty)
      if (e.key === 'Escape' && !hasPrimaryModifiers) {
        if (coord.selectedAssetIds.length > 0) {
          coord.clearSelection();
          return;
        }
        if (lib.cutAssetIds.length > 0) {
          lib.clearCutAssets();
          return;
        }
      }

      // Delete / Backspace: in Trash opens permanent-delete confirm modal; elsewhere moves selection to Trash with Undo
      if (
        (e.key === 'Delete' || e.key === 'Backspace') &&
        coord.selectedAssetIds.length > 0 &&
        !inMoodboard &&
        !document.querySelector('[role="dialog"][aria-modal="true"]')
      ) {
        e.preventDefault();
        const ids = [...coord.selectedAssetIds];
        if (coord.destination.type === 'trash') {
          setPendingTrashDeleteIds(ids);
        } else {
          coord.clearSelection();
          void lib.updateAssets({ assetIDs: ids, isTrashed: true }, coord.destination, {
            undoMessage: `已将 ${ids.length} 项移入回收站`,
            undoPatch: { assetIDs: ids, isTrashed: false },
          });
        }
        return;
      }

      // Inbox 1–9 quick triage shortcuts
      if (
        coord.destination.type === 'inbox' &&
        !hasPrimaryModifiers &&
        /^[1-9]$/.test(e.key)
      ) {
        const idx = Number(e.key) - 1;
        const flatFolders = flattenFolderTree(buildFolderTree(lib.folders));
        const folderNode = flatFolders[idx];
        const targetIds =
          coord.selectedAssetIds.length > 0
            ? coord.selectedAssetIds
            : lib.assets[0]
              ? [lib.assets[0].id]
              : [];
        if (folderNode && targetIds.length > 0) {
          e.preventDefault();
          coord.clearSelection();
          void lib.updateAssets(
            {
              assetIDs: targetIds,
              folderAssignment: { folder: folderNode.folder.id },
            },
            coord.destination,
            {
              undoMessage: `已分拣 ${targetIds.length} 项到「${folderNode.folder.name}」`,
              undoPatch: { assetIDs: targetIds, folderAssignment: 'inbox' },
            },
          );
        }
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, []);

  // Capture-phase unmodified Spacebar Quick Look coordinator (Pitfall 4: ignores CapsLock/NumLock/Fn,
  // blurs underlying focus before opening Quick Look, opens plain webBookmarks in default browser).
  useEffect(() => {
    const handleSpaceCapture = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.isComposing || e.keyCode === 229 || e.code !== 'Space') return;
      if (e.ctrlKey || e.altKey || e.metaKey || e.shiftKey) return;

      const coord = useCoordinatorStore.getState();
      if (
        coord.jumpOpen ||
        coord.captureOpen ||
        coord.settingsOpen ||
        coord.onboardingOpen ||
        coord.moodboardGeneratorOpen
      ) {
        return;
      }

      if (
        document.querySelector(
          '[data-charkle-popover-open="true"], [data-inspector-delete-open="true"], [data-quicklook-delete-open="true"], [role="dialog"][aria-modal="true"]:not([data-testid="quicklook-overlay"]):not([data-testid="smart-dedup-modal"])',
        )
      ) {
        return;
      }

      // Case 1: Quick Look is OPEN -> unmodified Space closes Quick Look (unless editing in Inspector)
      if (coord.quickLookAssetId) {
        if (isTypingTarget(e.target) || isTypingTarget(document.activeElement)) return;
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        if (e.repeat) return;
        coord.closeQuickLook();
        return;
      }

      // When Smart Deduplication modal is open without Quick Look, don't capture Space for background gallery
      if (coord.dedupOpen) return;

      // Case 2: Quick Look is CLOSED -> Moodboard & Pinterest own Space / canvas interactions
      const inMoodboard =
        coord.destination.type === 'moodboardsHome' ||
        coord.destination.type === 'moodboard' ||
        coord.destination.type === 'pinterest';
      if (inMoodboard) return;
      if (isTypingTarget(e.target) || isTypingTarget(document.activeElement)) return;

      const lib = useLibraryStore.getState();
      const targetId = coord.selectedAssetIds[0] ?? lib.assets[0]?.id;
      if (!targetId) return;

      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      if (e.repeat) return;

      (document.activeElement as HTMLElement | null)?.blur?.();

      const targetAsset =
        lib.assets.find((a) => a.id === targetId) ??
        lib.allAssets.find((a) => a.id === targetId);
      if (isPlainWebBookmark(targetAsset) && targetAsset?.sourceURL) {
        const domain = formatBookmarkDomain(targetAsset);
        void getTransport()
          .openExternalUrl(targetAsset.sourceURL)
          .then(() => {
            coord.pushToast({
              message: `已在默认浏览器中打开 ${domain}`,
              tone: 'info',
            });
          })
          .catch(() => {
            coord.pushToast({ message: '无法在默认浏览器中打开链接', tone: 'error' });
          });
        void lib.markAssetOpened(targetAsset.id);
      } else {
        coord.openQuickLook(targetId, findAssetCardOriginRect(targetId));
      }
    };

    window.addEventListener('keydown', handleSpaceCapture, true);
    return () => window.removeEventListener('keydown', handleSpaceCapture, true);
  }, []);

  // Global Ctrl+V clipboard capture for images & URLs (including short share copy)
  useEffect(() => {
    const handlePaste = async (e: ClipboardEvent) => {
      if (isTypingTarget(e.target) || isTypingTarget(document.activeElement)) return;
      const coord = useCoordinatorStore.getState();
      if (
        coord.jumpOpen ||
        coord.captureOpen ||
        coord.quickLookAssetId ||
        coord.settingsOpen ||
        coord.onboardingOpen ||
        coord.moodboardGeneratorOpen ||
        coord.dedupOpen ||
        document.querySelector('[role="dialog"][aria-modal="true"]')
      ) {
        return;
      }
      const lib = useLibraryStore.getState();
      const targetFolderId =
        coord.destination.type === 'folder' ? coord.destination.id : null;

      try {
        const items = Array.from(e.clipboardData?.items ?? []);
        const imageItem = items.find((i) => i.type.startsWith('image/'));
        if (imageItem) {
          const blob = imageItem.getAsFile();
          if (blob) {
            const dataUrl = await new Promise<string>((resolve) => {
              const reader = new FileReader();
              reader.onload = () => resolve(String(reader.result ?? ''));
              reader.onerror = () => resolve('');
              reader.readAsDataURL(blob);
            });
            const base64 = dataUrl.includes(',') ? dataUrl.split(',')[1] : dataUrl;
            if (base64) {
              await lib.ingestImageBase64(
                base64,
                `clipboard-${Date.now()}.png`,
                null,
                targetFolderId,
                coord.destination,
              );
            }
            return;
          }
        }

        const text = e.clipboardData?.getData('text/plain') ?? '';
        const extractedUrl = extractWebUrlFromPaste(text);
        if (extractedUrl) {
          await lib.ingestUrl(extractedUrl, null, null, targetFolderId, coord.destination);
        }
      } catch (err) {
        coord.pushToast({
          message: `剪贴板导入失败：${err instanceof Error ? err.message : String(err)}`,
          tone: 'error',
        });
      }
    };

    window.addEventListener('paste', handlePaste);
    return () => window.removeEventListener('paste', handlePaste);
  }, []);

  const isMoodboardView =
    destination.type === 'moodboardsHome' || destination.type === 'moodboard';
  const isPinterestView = destination.type === 'pinterest';
  const showMainInspector = inspectorOpen && !isMoodboardView && !isPinterestView;
  const { sidebarEffectiveWidth, inspectorEffectiveWidth } = resolveEffectivePaneWidths({
    windowWidth,
    sidebarOpen,
    sidebarCollapsed,
    sidebarWidth,
    inspectorOpen: showMainInspector,
    inspectorWidth,
    priority: isResizingPane,
  });

  return (
    <div className="w-screen h-screen min-h-0 min-w-0 flex overflow-hidden bg-transparent text-[var(--text-primary)]">
      {/* Left Full-Height Mica Alt Navigation Rail (draggable 188–420px / 76px collapsed rail) */}
      <div
        aria-hidden={!sidebarOpen}
        inert={!sidebarOpen}
        data-testid="sidebar-slot"
        style={{ width: sidebarEffectiveWidth }}
        className={[
          'shrink-0 min-h-0 h-full overflow-hidden flex justify-end',
          sidebarOpen ? '' : 'pointer-events-none',
        ].join(' ')}
      >
        <div
          className="win-drawer-content h-full flex shrink-0"
          style={{
            width: sidebarEffectiveWidth,
            transform: sidebarOpen ? 'translateX(0)' : 'translateX(-12px)',
            opacity: sidebarOpen ? 1 : 0,
            transition: isResizingPane === 'sidebar' ? 'none' : undefined,
          }}
        >
          <SidebarView />
        </div>
      </div>

      {sidebarOpen && (
        <PaneResizeDivider
          mode="sidebar"
          isCollapsed={sidebarCollapsed}
          currentWidth={sidebarEffectiveWidth}
          minWidth={MIN_SIDEBAR_WIDTH}
          maxWidth={MAX_SIDEBAR_WIDTH}
          defaultWidth={DEFAULT_SIDEBAR_WIDTH}
          label="调整左侧边栏宽度"
          testId="sidebar-resize-divider"
          onResizeStart={() => setResizingPane('sidebar')}
          onResize={(next) => {
            const clamped = clampSidebarWidth(
              next,
              windowWidth,
              showMainInspector,
              inspectorEffectiveWidth,
            );
            setSidebarWidth(clamped);
          }}
          onExpandFromCollapsed={(initialWidth) => {
            const clamped = clampSidebarWidth(
              initialWidth,
              windowWidth,
              showMainInspector,
              inspectorEffectiveWidth,
            );
            setSidebarCollapsed(false);
            setSidebarWidth(clamped);
          }}
          onResizeEnd={(finalWidth) => {
            setResizingPane(null);
            if (!useCoordinatorStore.getState().sidebarCollapsed) {
              const clamped = clampSidebarWidth(
                finalWidth,
                windowWidth,
                showMainInspector,
                inspectorEffectiveWidth,
              );
              commitSidebarWidth(clamped);
            }
          }}
          onReset={() => {
            if (sidebarCollapsed) setSidebarCollapsed(false);
            resetSidebarWidth();
          }}
        />
      )}

      {/* Right Column: Slim 40px Mica Titlebar + Elevated Rounded Content Surface */}
      <div className="charkle-mica-chrome flex-1 min-w-0 min-h-0 h-full flex flex-col overflow-hidden">
        <Titlebar />

        <div className="charkle-gallery-surface rounded-tl-[8px] flex-1 min-w-0 min-h-0 flex overflow-hidden bg-[var(--bg-gallery)]">
          <div className="flex-1 min-w-0 min-h-0 h-full flex overflow-hidden">
            {isPinterestView ? (
              <ErrorBoundary fullScreen={false} title="Pinterest 空间遇到意外中断">
                <PinterestWorkspace />
              </ErrorBoundary>
            ) : isMoodboardView ? (
              <ErrorBoundary fullScreen={false} title="情绪板视图遇到意外中断">
                <MoodboardsHome />
              </ErrorBoundary>
            ) : (
              <ErrorBoundary fullScreen={false} title="素材画廊遇到意外中断">
                <GalleryView />
              </ErrorBoundary>
            )}
          </div>

          {showMainInspector && (
            <PaneResizeDivider
              mode="inspector"
              currentWidth={inspectorEffectiveWidth}
              minWidth={MIN_INSPECTOR_WIDTH}
              maxWidth={MAX_INSPECTOR_WIDTH}
              defaultWidth={DEFAULT_INSPECTOR_WIDTH}
              label="调整右侧检查器宽度"
              testId="inspector-resize-divider"
              onResizeStart={() => setResizingPane('inspector')}
              onResize={(next) => {
                const clamped = clampInspectorWidth(next, windowWidth, sidebarEffectiveWidth);
                setInspectorWidth(clamped);
              }}
              onResizeEnd={(finalWidth) => {
                setResizingPane(null);
                const clamped = clampInspectorWidth(finalWidth, windowWidth, sidebarEffectiveWidth);
                commitInspectorWidth(clamped);
              }}
              onReset={resetInspectorWidth}
            />
          )}

          {/* Right Draggable Inspector Slot (260–480px, default 300px, zero per-frame width transition) */}
          <div
            aria-hidden={!showMainInspector}
            inert={!showMainInspector}
            data-testid="main-inspector-slot"
            style={{ width: showMainInspector ? inspectorEffectiveWidth : 0 }}
            className={[
              'shrink-0 min-h-0 h-full overflow-hidden flex justify-start',
              showMainInspector ? '' : 'pointer-events-none',
            ].join(' ')}
          >
            <div
              className="win-drawer-content shrink-0 min-h-0 h-full flex"
              style={{
                width: showMainInspector ? inspectorEffectiveWidth : inspectorWidth,
                transform: showMainInspector ? 'translateX(0)' : 'translateX(16px)',
                opacity: showMainInspector ? 1 : 0,
                transition: isResizingPane === 'inspector' ? 'none' : undefined,
              }}
            >
              <ErrorBoundary fullScreen={false} title="检查器遇到意外中断">
                <InspectorView active={showMainInspector} />
              </ErrorBoundary>
            </div>
          </div>
        </div>
      </div>

      <SmartDeduplicationModal />
      <ErrorBoundary fullScreen={false} title="快速预览遇到意外中断">
        <QuickLookOverlay />
      </ErrorBoundary>
      <JumpAnywhereModal />
      <QuickCaptureModal />
      <MoodboardGeneratorModal
        open={moodboardGeneratorOpen}
        onClose={() => setMoodboardGeneratorOpen(false)}
      />
      <SettingsOverlay />
      <AppUpdateModal />
      <OnboardingStudio />
      <ModalShell
        open={pendingTrashDeleteIds.length > 0}
        onClose={() => setPendingTrashDeleteIds([])}
        title={`彻底删除 ${pendingTrashDeleteIds.length} 项素材？`}
        width="sm"
        footer={
          <>
            <Button variant="standard" onClick={() => setPendingTrashDeleteIds([])}>
              取消
            </Button>
            <Button
              variant="danger"
              onClick={async () => {
                const ids = [...pendingTrashDeleteIds];
                setPendingTrashDeleteIds([]);
                await useLibraryStore
                  .getState()
                  .permanentlyDeleteAssets(ids, useCoordinatorStore.getState().destination);
              }}
            >
              彻底删除
            </Button>
          </>
        }
      >
        <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed charkle-prose">
          彻底删除后将无法从回收站恢复。
        </p>
      </ModalShell>
      <PointerDragGhostLayer />
      <ToastHost />
      <WindowResizeEdges />
    </div>
  );
};

export default App;
