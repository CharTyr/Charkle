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
    inspectorOpen: true,
    layoutMode: 'verticalMasonry',
    cardScale: 236,
    destination: { type: 'allItems' },
    selectedAssetIds: [],
    lastSelectedAssetId: null,
    quickLookAssetId: null,
    quickLookOriginRect: null,
    jumpOpen: false,
    captureOpen: false,
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

  it('operates TopEdgeDropShelf in Compact and Expanded Full-Waterfall modes with clipboard collect & OLE drag-out', async () => {
    render(<TopEdgeDropShelf />);

    await waitFor(() => {
      expect(screen.getByTestId('top-edge-drop-shelf')).toHaveAttribute('data-mode', 'compact');
      expect(screen.getByText(/charkle_design/)).toBeInTheDocument();
    });

    // Hit rect is synchronized to Win32 WM_NCHITTEST
    expect(mock.lastShelfHitRect).not.toBeNull();

    // Switch target routing pill
    fireEvent.click(screen.getByRole('radio', { name: '当前活跃情绪板' }));
    expect(screen.getByRole('radio', { name: '当前活跃情绪板' })).toHaveAttribute(
      'aria-checked',
      'true',
    );

    // Quick-collect clipboard URL chip
    fireEvent.click(screen.getByRole('button', { name: '立即采集' }));
    await waitFor(() => {
      expect(screen.getByText(/已采集 1 项剪贴板内容/)).toBeInTheDocument();
    });

    // Expand to Full-Waterfall Shelf mode & trigger OLE outbound drag
    fireEvent.click(screen.getByRole('button', { name: '展开为全瀑布流抽屉' }));
    expect(screen.getByTestId('top-edge-drop-shelf')).toHaveAttribute('data-mode', 'waterfall');

    const dragOutBtn = screen.getByRole('button', { name: '原生拖出 暖调建筑海报参考' });
    fireEvent.mouseDown(dragOutBtn, { button: 0 });
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

  it('exposes Desktop Integration popover (hotkeys/autostart/OCR) and Inspector OLE drag-out + OCR extraction', async () => {
    render(<App />);

    await waitFor(() => {
      expect(
        document.querySelector('[data-asset-id="20000000-0000-4000-8000-000000000001"]'),
      ).not.toBeNull();
    });

    // Open Desktop Integration Popover in Titlebar
    fireEvent.click(screen.getByRole('button', { name: '桌面集成设置' }));
    await waitFor(() => {
      expect(screen.getByText('Alt+Shift+A')).toBeInTheDocument();
      expect(screen.getByText('Alt+Shift+S')).toBeInTheDocument();
      expect(screen.getByText('Alt+Shift+V')).toBeInTheDocument();
      expect(screen.getByText('zh-Hans-CN')).toBeInTheDocument();
      expect(screen.getByText('charkle://')).toBeInTheDocument();
    });

    // Select asset 1 -> click Inspector OCR & OLE Drag-Out buttons
    const card = document.querySelector('[data-asset-id="20000000-0000-4000-8000-000000000001"]')!;
    fireEvent.click(card);

    await waitFor(() => {
      expect(screen.getByRole('button', { name: /提取文字/ })).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole('button', { name: /提取文字/ }));
    await waitFor(() => {
      expect(screen.getByText(/识别文字：Charkle 视觉灵感参考/)).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole('button', { name: /拖出原文件/ }));
    await waitFor(() => {
      expect(mock.lastOutboundDragIds).toEqual(['20000000-0000-4000-8000-000000000001']);
    });
  });
});
