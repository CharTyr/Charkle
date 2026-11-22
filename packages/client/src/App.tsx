import React, { useEffect } from 'react';
import { createDefaultAssetBatchPatch, hasVisibleLibraryChanges } from '@charkle/shared';
import { connectCharkleSSE } from './api/sse';
import { applyThemeToDocument, ToastHost } from './design-system';
import { AuthGate } from './features/auth/AuthGate';
import { GalleryView } from './features/gallery/GalleryView';
import { InspectorView } from './features/inspector/InspectorView';
import { JumpAnywhereModal } from './features/jump/JumpAnywhereModal';
import {
  MoodboardGeneratorModal,
  MoodboardsHomeView,
  MoodboardWorkspaceView,
} from './features/moodboard';
import { QuickLookOverlay } from './features/quicklook/QuickLookOverlay';
import { SettingsModal } from './features/settings';
import { QuickDropShelf } from './features/shelf';
import { SidebarView } from './features/sidebar/SidebarView';
import { useAuthStore } from './stores/authStore';
import { useCoordinatorStore } from './stores/coordinatorStore';
import { useLibraryStore } from './stores/libraryStore';
import { useMoodboardStore } from './stores/moodboardStore';
import { useSyncAIStore } from './stores/syncAIStore';

function isInputElement(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  const tag = target.tagName;
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return true;
  return target.isContentEditable;
}

const CharkleWorkspace: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const themeMode = useCoordinatorStore((s) => s.themeMode);
  const brandIconVariant = useCoordinatorStore((s) => s.brandIconVariant);

  // Keep OS color scheme synced when themeMode === 'system'
  useEffect(() => {
    applyThemeToDocument(themeMode, brandIconVariant);
    if (themeMode !== 'system' || !window.matchMedia) return;
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const handler = () => applyThemeToDocument('system', brandIconVariant);
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, [themeMode, brandIconVariant]);

  // Initial library bootstrap + SSE subscription
  useEffect(() => {
    void useLibraryStore.getState().bootstrap();

    const conn = connectCharkleSSE(
      (event) => {
        const syncAI = useSyncAIStore.getState();
        const lib = useLibraryStore.getState();
        const mb = useMoodboardStore.getState();

        switch (event.type) {
          case 'sync.status':
            syncAI.setSyncStatus(event.status);
            break;
          case 'sync.completed':
            syncAI.setSyncCompleted(event.report, event.status);
            if (hasVisibleLibraryChanges(event.report)) {
              void lib.refreshSidebarMetadata();
              void lib.loadAssets();
              void mb.loadBoards();
            }
            break;
          case 'library.changed':
          case 'library.enriched':
            lib.bumpCacheBust();
            void lib.refreshSidebarMetadata();
            void lib.loadAssets();
            void lib.loadRecentActivity(24);
            break;
          case 'board.updated':
            void mb.loadBoards();
            if (
              mb.activeDocument &&
              mb.activeDocument.id === event.boardID &&
              !event.deleted &&
              !mb.savingBoard
            ) {
              // Refresh board silently if modified externally (e.g. MCP or another tab)
              void mb.openBoard(event.boardID);
            }
            break;
          case 'ai.curate.step':
            mb.pushAgentStep(event.step);
            break;
          case 'ping':
            break;
        }
      },
      {
        onConnectionChange: (connected) => useSyncAIStore.getState().setSSEConnected(connected),
        onUnauthorized: () => useAuthStore.getState().handleUnauthorized(),
      },
    );

    return () => {
      conn.disconnect();
    };
  }, []);

  // Re-fetch assets whenever navigation destination changes
  useEffect(() => {
    const lib = useLibraryStore.getState();
    lib.clearSelection();
    lib.clearSemanticSearch();

    if (destination.type === 'moodboard') {
      void useMoodboardStore.getState().openBoard(destination.id);
    } else if (destination.type === 'moodboardsHome') {
      void useMoodboardStore.getState().loadBoards();
    } else {
      void lib.loadAssets(destination);
    }
  }, [destination]);

  // Global Studio Keyboard Shortcuts
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      const key = e.key.toLowerCase();
      const coord = useCoordinatorStore.getState();
      const lib = useLibraryStore.getState();

      // Always-available command shortcuts
      if (mod && key === 'j') {
        e.preventDefault();
        coord.toggleJumpAnywhere();
        return;
      }
      if (mod && e.key === ',') {
        e.preventDefault();
        coord.openSettings();
        return;
      }
      if (mod && e.key === '\\') {
        e.preventDefault();
        coord.toggleSidebar();
        return;
      }
      if (mod && key === 'i') {
        e.preventDefault();
        coord.toggleInspector();
        return;
      }
      if (mod && e.shiftKey && key === 's') {
        e.preventDefault();
        lib.setShowVisualFilterBar(!lib.showVisualFilterBar);
        return;
      }

      // Skip gallery-scoped shortcuts when typing or inside modals/Quick Look/Moodboard canvas
      if (isInputElement(e.target)) return;
      if (
        coord.quickLookAssetID ||
        coord.jumpAnywhereOpen ||
        coord.settingsOpen ||
        coord.generatorModalOpen
      ) {
        return;
      }

      const inGallery =
        coord.destination.type !== 'moodboard' && coord.destination.type !== 'moodboardsHome';
      if (!inGallery) return;

      if (mod && key === 'a') {
        e.preventDefault();
        lib.selectAllVisible();
        return;
      }

      if (mod && key === 'x' && lib.selectedAssetIDs.size > 0) {
        e.preventDefault();
        lib.setCutAssetIDs(lib.selectedAssetIDs);
        coord.pushToast({
          tone: 'info',
          message: `已剪切 ${lib.selectedAssetIDs.size} 项素材，可前往目标文件夹粘贴移动`,
        });
        return;
      }

      if (mod && key === 'v' && lib.cutAssetIDs.size > 0) {
        if (coord.destination.type === 'folder' || coord.destination.type === 'inbox') {
          e.preventDefault();
          const cutIDs = Array.from(lib.cutAssetIDs);
          lib.setCutAssetIDs([]);
          void lib.batchPatch(
            createDefaultAssetBatchPatch(cutIDs, {
              folderAssignment:
                coord.destination.type === 'folder'
                  ? { type: 'folder', folderID: coord.destination.id }
                  : { type: 'inbox' },
            }),
          );
          coord.pushToast({ tone: 'success', message: `已移动 ${cutIDs.length} 项素材` });
          return;
        }
      }

      if (e.key === ' ') {
        const targetID =
          Array.from(lib.selectedAssetIDs)[0] ?? (lib.assets.length > 0 ? lib.assets[0].id : null);
        if (targetID) {
          e.preventDefault();
          coord.openQuickLook(targetID);
        }
        return;
      }

      if (e.key === 'Escape' && lib.selectedAssetIDs.size > 0) {
        e.preventDefault();
        lib.clearSelection();
        return;
      }

      if (
        (e.key === 'Backspace' || e.key === 'Delete') &&
        lib.selectedAssetIDs.size > 0 &&
        coord.destination.type !== 'trash'
      ) {
        e.preventDefault();
        void lib.trashAssets(Array.from(lib.selectedAssetIDs));
        return;
      }

      // Inbox 1-9 Quick Archive (`PARITY_SPEC.md` §6)
      if (
        coord.destination.type === 'inbox' &&
        !mod &&
        !e.altKey &&
        !e.shiftKey &&
        /^[1-9]$/.test(e.key)
      ) {
        const folderIdx = Number(e.key) - 1;
        const folder = lib.folders[folderIdx];
        if (!folder) return;
        const targetIDs =
          lib.selectedAssetIDs.size > 0
            ? Array.from(lib.selectedAssetIDs)
            : lib.assets.length > 0
              ? [lib.assets[0].id]
              : [];
        if (targetIDs.length === 0) return;

        e.preventDefault();
        void lib
          .batchPatch(
            createDefaultAssetBatchPatch(targetIDs, {
              folderAssignment: { type: 'folder', folderID: folder.id },
            }),
          )
          .then(() => {
            coord.pushToast({
              tone: 'success',
              message: `已将 ${targetIDs.length} 项归档至「${folder.name}」`,
              actionLabel: '撤销',
              onAction: () => {
                void lib.batchPatch(
                  createDefaultAssetBatchPatch(targetIDs, {
                    folderAssignment: { type: 'inbox' },
                  }),
                );
              },
            });
          });
      }
    };

    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  return (
    <div className="relative h-full w-full flex overflow-hidden bg-[var(--bg-gallery)] text-[var(--text-primary)]">
      {/* Left Navigation Sidebar */}
      <SidebarView />

      {/* Center Workspace Stage (top 24px reserved for flush 22px Quick Drop Notch) */}
      <main className="flex-1 min-w-0 h-full pt-[24px] flex flex-col overflow-hidden">
        {destination.type === 'moodboardsHome' ? (
          <MoodboardsHomeView />
        ) : destination.type === 'moodboard' ? (
          <MoodboardWorkspaceView boardID={destination.id} />
        ) : (
          <GalleryView />
        )}
      </main>

      {/* Right Collapsible Inspector */}
      <InspectorView />

      {/* Floating Overlays, Shelf & Studio Modals */}
      <QuickDropShelf />
      <QuickLookOverlay />
      <JumpAnywhereModal />
      <MoodboardGeneratorModal />
      <SettingsModal />
      <ToastHost />
    </div>
  );
};

export const App: React.FC = () => {
  return (
    <AuthGate>
      <CharkleWorkspace />
    </AuthGate>
  );
};

export default App;
