import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it } from 'vitest';
import { App } from '../App';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  useSyncAIStore,
} from '../stores';
import { createDefaultFilterCriteria } from '../types/domain';

function resetAllStores() {
  useCoordinatorStore.setState({
    themeMode: 'light',
    surfaceState: null,
    sidebarOpen: true,
    sidebarCollapsed: false,
    inspectorOpen: true,
    inspectorTab: 'info',
    visualFilterBarOpen: false,
    layoutMode: 'verticalMasonry',
    cardScale: 236,
    destination: { type: 'allItems' },
    selectedAssetIds: [],
    lastSelectedAssetId: null,
    quickLookAssetId: null,
    quickLookOriginRect: null,
    pendingGalleryReveal: null,
    jumpOpen: false,
    captureOpen: false,
    settingsOpen: false,
    settingsTab: 'general',
    onboardingOpen: false,
    onboardingDone: true,
    moodboardGeneratorOpen: false,
    activeMoodboardId: null,
    toasts: [],
  });
  useLibraryStore.setState({
    assets: [],
    folders: [],
    smartFolders: [],
    tagCounts: [],
    inboxCount: 0,
    criteria: createDefaultFilterCriteria(),
    semanticSearch: false,
    loading: false,
    bootstrapped: false,
    error: null,
  });
  useMoodboardStore.setState({
    boards: [],
    activeBoard: null,
    candidatePool: [],
    selectedNodeIds: [],
    historyPast: [],
    historyFuture: [],
    loading: false,
  });
  useSyncAIStore.setState({
    syncConfig: null,
    syncStatus: null,
    cacheStats: null,
    syncing: false,
  });
}

describe('macOS Native Parity: Quick Look Inspector Sync, Moodboard Reveal-in-Library & Shelf Settings', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    localStorage.clear();
    mock = new InMemoryMockTransport(true);
    setTransport(mock);
    resetAllStores();
  });

  it('synchronizes Quick Look Inspector visibility and active tab 1:1 with main workspace & supports Space toggle', async () => {
    render(<App />);

    await waitFor(() => {
      expect(
        document.querySelector('[data-asset-id="20000000-0000-4000-8000-000000000001"]'),
      ).not.toBeNull();
    });

    const card = document.querySelector('[data-asset-id="20000000-0000-4000-8000-000000000001"]')!;
    fireEvent.click(card);

    // Spacebar opens Quick Look deterministically
    fireEvent.keyDown(window, { code: 'Space', key: ' ' });
    await waitFor(() => {
      expect(screen.getByTestId('quicklook-overlay')).toBeInTheDocument();
    });

    // Switch Inspector tab to "类似项目" inside Quick Look and verify coordinator store stays synchronized
    const similarButtons = screen.getAllByRole('radio', { name: /类似项目/ });
    fireEvent.click(similarButtons[similarButtons.length - 1]);
    expect(useCoordinatorStore.getState().inspectorTab).toBe('similar');

    // Spacebar closes Quick Look cleanly
    fireEvent.keyDown(window, { code: 'Space', key: ' ' });
    await waitFor(() => {
      expect(useCoordinatorStore.getState().quickLookAssetId).toBeNull();
    });
  });

  it('supports Moodboard node right-click "在素材库中定位" with return-to-board toast CTA', async () => {
    render(<App />);

    await waitFor(() => {
      expect(useLibraryStore.getState().assets.length).toBeGreaterThan(0);
    });

    const board = await useMoodboardStore.getState().createBoard('春季视觉测试板', '', 'autoEditorial');
    await act(async () => {
      useCoordinatorStore.getState().setDestination({ type: 'moodboard', id: board.id });
    });

    await waitFor(() => {
      expect(screen.getByTestId('moodboard-studio-view')).toBeInTheDocument();
    });

    await act(async () => {
      useMoodboardStore.getState().addAssetNodeAt('20000000-0000-4000-8000-000000000001');
    });

    await waitFor(() => {
      expect(document.querySelector('[data-board-node-id]')).not.toBeNull();
    });

    const nodeEl = document.querySelector('[data-board-node-id]')!;
    fireEvent.contextMenu(nodeEl, { clientX: 240, clientY: 220 });

    await waitFor(() => {
      expect(screen.getByTestId('moodboard-node-context-menu')).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole('button', { name: '在素材库中定位' }));

    await waitFor(() => {
      expect(screen.getByTestId('gallery-stage')).toBeInTheDocument();
      expect(useCoordinatorStore.getState().selectedAssetIds).toEqual([
        '20000000-0000-4000-8000-000000000001',
      ]);
      expect(screen.getByRole('button', { name: '返回情绪板' })).toBeInTheDocument();
    });

    // Clicking the toast CTA returns directly back to the source moodboard
    fireEvent.click(screen.getByRole('button', { name: '返回情绪板' }));
    await waitFor(() => {
      expect(useCoordinatorStore.getState().destination).toEqual({
        type: 'moodboard',
        id: board.id,
      });
    });
  });

  it('persists DropShelf settings via Settings Overlay -> DropShelf pane', async () => {
    render(<App />);

    await act(async () => {
      useCoordinatorStore.getState().openSettings('dropShelf');
    });
    await waitFor(() => {
      expect(screen.getByTestId('settings-pane-dropShelf')).toBeInTheDocument();
    });

    const hoverSwitch = screen.getByRole('switch', { name: /鼠标悬停屏幕顶部中央自动唤出/ });
    expect(hoverSwitch).toHaveAttribute('aria-checked', 'true');
    fireEvent.click(hoverSwitch);

    await waitFor(async () => {
      const saved = await mock.getShelfSettings();
      expect(saved.hoverTriggerEnabled).toBe(false);
    });
  });
});
