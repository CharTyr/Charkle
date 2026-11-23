import React, { useEffect } from 'react';
import { getTransport } from './api/transport';
import { ToastHost } from './design-system';
import { QuickCaptureModal } from './features/capture/QuickCaptureModal';
import { Titlebar } from './features/chrome/Titlebar';
import { GalleryView } from './features/gallery/GalleryView';
import { InspectorView } from './features/inspector/InspectorView';
import { JumpAnywhereModal } from './features/jump/JumpAnywhereModal';
import { MoodboardsHomePlaceholder } from './features/moodboard/MoodboardsHomePlaceholder';
import { QuickLookOverlay } from './features/quicklook/QuickLookOverlay';
import { SidebarView } from './features/sidebar/SidebarView';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  useSyncAIStore,
} from './stores';
import { buildFolderTree, flattenFolderTree } from './types/domain';

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

export const App: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const sidebarOpen = useCoordinatorStore((s) => s.sidebarOpen);
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const syncWindowChrome = useCoordinatorStore((s) => s.syncWindowChrome);

  const bootstrap = useLibraryStore((s) => s.bootstrap);
  const refreshAll = useLibraryStore((s) => s.refreshAll);
  const patchSingleAssetInMemory = useLibraryStore((s) => s.patchSingleAssetInMemory);

  const fetchBoards = useMoodboardStore((s) => s.fetchBoards);
  const refreshSyncAndCache = useSyncAIStore((s) => s.refreshSyncAndCache);
  const setSyncStatus = useSyncAIStore((s) => s.setSyncStatus);

  // Initial bootstrap + Win32 Mica chrome sync + live Tauri event bridge
  useEffect(() => {
    void syncWindowChrome();
    void bootstrap(useCoordinatorStore.getState().destination);
    void fetchBoards();
    void refreshSyncAndCache();

    let unlisten: (() => void) | null = null;
    void getTransport()
      .subscribeEvents({
        onLibraryChanged: () => {
          void refreshAll(useCoordinatorStore.getState().destination);
        },
        onSyncStatus: (status) => {
          setSyncStatus(status);
        },
        onAssetEnriched: (assetId) => {
          void getTransport()
            .fetchAsset(assetId)
            .then((asset) => {
              if (asset) patchSingleAssetInMemory(asset);
            });
        },
        onBoardUpdated: () => {
          void fetchBoards();
        },
      })
      .then((fn) => {
        unlisten = fn;
      })
      .catch(() => {});

    return () => {
      unlisten?.();
    };
  }, [
    syncWindowChrome,
    bootstrap,
    fetchBoards,
    refreshSyncAndCache,
    refreshAll,
    setSyncStatus,
    patchSingleAssetInMemory,
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

  // Refresh assets whenever sidebar destination changes
  useEffect(() => {
    if (destination.type === 'moodboardsHome' || destination.type === 'moodboard') {
      void fetchBoards();
      return;
    }
    void refreshAll(destination);
  }, [destination, refreshAll, fetchBoards]);

  // Global keyboard shortcuts
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      const mod = e.ctrlKey || e.metaKey;
      const coord = useCoordinatorStore.getState();
      const lib = useLibraryStore.getState();

      // Ctrl+J works everywhere (0ms instant Jump Anywhere)
      if (mod && e.key.toLowerCase() === 'j') {
        e.preventDefault();
        coord.setJumpOpen(!coord.jumpOpen);
        return;
      }

      if (mod && e.key.toLowerCase() === 'n') {
        e.preventDefault();
        coord.setCaptureOpen(true);
        return;
      }

      if (mod && e.key === '\\') {
        e.preventDefault();
        coord.toggleSidebar();
        return;
      }

      if (mod && e.key.toLowerCase() === 'i') {
        e.preventDefault();
        coord.toggleInspector();
        return;
      }

      if (mod && e.key === '1') {
        e.preventDefault();
        coord.setLayoutMode('verticalMasonry');
        return;
      }
      if (mod && e.key === '2') {
        e.preventDefault();
        coord.setLayoutMode('horizontalJustified');
        return;
      }
      if (mod && e.key === '3') {
        e.preventDefault();
        coord.setLayoutMode('galleryFilmstrip');
        return;
      }

      if (isTypingTarget(e.target) || coord.jumpOpen || coord.captureOpen) {
        return;
      }

      // Space: toggle Quick Look
      if (e.code === 'Space' && !coord.quickLookAssetId) {
        const targetId = coord.selectedAssetIds[0] ?? lib.assets[0]?.id;
        if (targetId) {
          e.preventDefault();
          coord.openQuickLook(targetId, null);
        }
        return;
      }

      if (coord.quickLookAssetId) return;

      // Ctrl+A select all in gallery
      if (mod && e.key.toLowerCase() === 'a') {
        e.preventDefault();
        coord.setSelection(lib.assets.map((a) => a.id));
        return;
      }

      // Escape clears selection
      if (e.key === 'Escape' && coord.selectedAssetIds.length > 0) {
        coord.clearSelection();
        return;
      }

      // Delete moves selection to Trash with Undo toast
      if (
        (e.key === 'Delete' || e.key === 'Backspace') &&
        coord.selectedAssetIds.length > 0 &&
        coord.destination.type !== 'trash'
      ) {
        e.preventDefault();
        const ids = [...coord.selectedAssetIds];
        coord.clearSelection();
        void lib.updateAssets({ assetIDs: ids, isTrashed: true }, coord.destination, {
          undoMessage: `已将 ${ids.length} 项移入回收站`,
          undoPatch: { assetIDs: ids, isTrashed: false },
        });
        return;
      }

      // Inbox 1–9 quick triage shortcuts
      if (
        coord.destination.type === 'inbox' &&
        !mod &&
        !e.altKey &&
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

  // Global Ctrl+V clipboard capture for images & URLs
  useEffect(() => {
    const handlePaste = async (e: ClipboardEvent) => {
      if (isTypingTarget(e.target)) return;
      const coord = useCoordinatorStore.getState();
      if (coord.jumpOpen || coord.captureOpen || coord.quickLookAssetId) return;
      const lib = useLibraryStore.getState();
      const targetFolderId =
        coord.destination.type === 'folder' ? coord.destination.id : null;

      const items = Array.from(e.clipboardData?.items ?? []);
      const imageItem = items.find((i) => i.type.startsWith('image/'));
      if (imageItem) {
        const blob = imageItem.getAsFile();
        if (blob) {
          const dataUrl = await new Promise<string>((resolve) => {
            const reader = new FileReader();
            reader.onload = () => resolve(String(reader.result ?? ''));
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

      const text = e.clipboardData?.getData('text/plain')?.trim() ?? '';
      if (/^https?:\/\/\S+$/i.test(text)) {
        await lib.ingestUrl(text, null, null, targetFolderId, coord.destination);
      }
    };

    window.addEventListener('paste', handlePaste);
    return () => window.removeEventListener('paste', handlePaste);
  }, []);

  const isMoodboardView =
    destination.type === 'moodboardsHome' || destination.type === 'moodboard';

  return (
    <div className="w-screen h-screen flex flex-col overflow-hidden text-[var(--text-primary)]">
      <Titlebar />

      <div className="flex-1 min-h-0 flex overflow-hidden">
        {sidebarOpen && <SidebarView />}
        {isMoodboardView ? <MoodboardsHomePlaceholder /> : <GalleryView />}
        {inspectorOpen && !isMoodboardView && <InspectorView />}
      </div>

      <QuickLookOverlay />
      <JumpAnywhereModal />
      <QuickCaptureModal />
      <ToastHost />
    </div>
  );
};

export default App;
