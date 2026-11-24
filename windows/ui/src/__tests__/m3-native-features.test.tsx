import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it } from 'vitest';
import { App } from '../App';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import { RegionCaptureOverlay } from '../features/capture/RegionCaptureOverlay';
import { TopEdgeDropShelf } from '../features/shelf/TopEdgeDropShelf';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  useSyncAIStore,
} from '../stores';
import { createDefaultFilterCriteria } from '../types/domain';

function resetStores() {
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
    onboardingOpen: false,
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
    loading: false,
  });
  useSyncAIStore.setState({
    syncConfig: null,
    syncStatus: null,
    cacheStats: null,
    syncing: false,
  });
}

describe('Charkle Windows M3 Drop Shelf, Region Capture, OLE Drag-Out & Desktop Integration', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    localStorage.clear();
    mock = new InMemoryMockTransport(true);
    setTransport(mock);
    resetStores();
  });

  it('operates TopEdgeDropShelf in Compact and Expanded Full-Waterfall modes with clipboard collect & 6px OLE drag-out', async () => {
    render(<TopEdgeDropShelf />);

    await waitFor(() => {
      expect(screen.getByTestId('top-edge-drop-shelf')).toHaveAttribute('data-mode', 'compact');
      expect(screen.getByText(/charkle_design/)).toBeInTheDocument();
    });

    // Strictly faithful to macOS NotchShelfView: no invented "顶部灵感抽屉" header
    expect(screen.queryByText('顶部灵感抽屉')).not.toBeInTheDocument();

    // Hit rect is synchronized to Win32 WM_NCHITTEST
    expect(mock.lastShelfHitRect).not.toBeNull();

    // Switch target routing pill
    fireEvent.click(screen.getByRole('radio', { name: '活跃情绪板' }));
    expect(screen.getByRole('radio', { name: '活跃情绪板' })).toHaveAttribute(
      'aria-checked',
      'true',
    );

    // Quick-collect clipboard URL chip inside Drop Well
    fireEvent.click(screen.getByRole('button', { name: /检测到剪贴板链接/ }));
    await waitFor(() => {
      expect(screen.getByText(/已采集 1 项剪贴板内容/)).toBeInTheDocument();
    });

    // Expand to Full-Waterfall mode & drag card past 6px threshold to trigger OLE outbound drag
    fireEvent.click(screen.getByRole('button', { name: '展开为全瀑布流抽屉' }));
    expect(screen.getByTestId('top-edge-drop-shelf')).toHaveAttribute('data-mode', 'waterfall');

    const cardEl = document.querySelector('[data-shelf-card-id="20000000-0000-4000-8000-000000000001"]')!;
    expect(cardEl).not.toBeNull();
    fireEvent.pointerDown(cardEl, { button: 0, clientX: 100, clientY: 100 });
    fireEvent.pointerMove(window, { clientX: 120, clientY: 120, buttons: 1 });
    fireEvent.pointerUp(window, { clientX: 120, clientY: 120 });

    await waitFor(() => {
      expect(mock.lastOutboundDragIds).toEqual(['20000000-0000-4000-8000-000000000001']);
    });
  });

  it('captures region selection with live pixel badge, 8x loupe canvas and commits 1:1 crop', async () => {
    render(<RegionCaptureOverlay tokenOverride="TEST-TOKEN" />);

    const overlay = screen.getByTestId('region-capture-overlay');
    fireEvent.mouseDown(overlay, { button: 0, clientX: 100, clientY: 120 });
    fireEvent.mouseMove(overlay, { clientX: 420, clientY: 360 });
    fireEvent.mouseUp(overlay);

    await waitFor(() => {
      expect(screen.getByTestId('capture-selection-rect')).toBeInTheDocument();
      expect(screen.getByTestId('capture-size-badge')).toBeInTheDocument();
      expect(screen.getByTestId('capture-loupe-canvas')).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole('button', { name: /保存截图/ }));
    await waitFor(() => {
      expect(mock.lastCommittedCrop).not.toBeNull();
      expect(mock.lastCommittedCrop?.token).toBe('TEST-TOKEN');
      expect(mock.lastCommittedCrop?.width).toBeGreaterThan(0);
      expect(mock.lastCommittedCrop?.height).toBeGreaterThan(0);
    });
  });

  it('exposes Desktop Integration settings (hotkeys/autostart/OCR) via Sidebar Settings entry and Inspector pointer OLE drag-out + OCR extraction', async () => {
    render(<App />);

    await waitFor(() => {
      expect(
        document.querySelector('[data-asset-id="20000000-0000-4000-8000-000000000001"]'),
      ).not.toBeNull();
    });

    // Open Settings via the single canonical Sidebar footer entry (Fluent 2 §3.3)
    fireEvent.click(screen.getByRole('button', { name: '打开设置中心' }));
    await waitFor(() => {
      expect(screen.getByTestId('settings-overlay')).toBeInTheDocument();
      expect(screen.getByRole('switch', { name: '开机自动启动 Charkle' })).toBeInTheDocument();
    });

    // Capture & Shortcuts pane exposes global hotkeys
    fireEvent.click(screen.getByRole('tab', { name: '采集与快捷键' }));
    await waitFor(() => {
      expect(screen.getByTestId('settings-pane-captureShortcuts')).toBeInTheDocument();
      expect(screen.getByText('Alt+Shift+A')).toBeInTheDocument();
      expect(screen.getByText('Alt+Shift+S')).toBeInTheDocument();
      expect(screen.getByText('Alt+Shift+V')).toBeInTheDocument();
    });

    // Advanced & About pane surfaces offline OCR languages
    fireEvent.click(screen.getByRole('tab', { name: '高级与关于' }));
    await waitFor(() => {
      expect(screen.getByTestId('settings-pane-advancedAbout')).toBeInTheDocument();
      expect(screen.getByText(/zh-Hans-CN/)).toBeInTheDocument();
    });

    // Protocol scheme stays registered in desktop integration status
    const desktopStatus = await mock.getDesktopIntegrationStatus();
    expect(desktopStatus.deepLinkScheme).toBe('charkle');

    // Close Settings cleanly before interacting with main workspace
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => {
      expect(screen.queryByTestId('settings-overlay')).not.toBeInTheDocument();
    });

    // Select asset 1 -> click Inspector OCR & Pointer-drag OLE Drag-Out chip
    const card = document.querySelector('[data-asset-id="20000000-0000-4000-8000-000000000001"]')!;
    fireEvent.click(card);

    await waitFor(() => {
      expect(screen.getByRole('button', { name: /提取文字/ })).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole('button', { name: /提取文字/ }));
    await waitFor(() => {
      expect(screen.getByText(/识别文字：Charkle 视觉灵感参考/)).toBeInTheDocument();
    });

    const dragOutChip = screen.getByRole('button', { name: /按住拖出/ });
    fireEvent.pointerDown(dragOutChip, { button: 0, clientX: 50, clientY: 50 });
    fireEvent.pointerMove(window, { clientX: 70, clientY: 70, buttons: 1 });
    fireEvent.pointerUp(window, { clientX: 70, clientY: 70 });

    await waitFor(() => {
      expect(mock.lastOutboundDragIds).toEqual(['20000000-0000-4000-8000-000000000001']);
    });
  });
});
