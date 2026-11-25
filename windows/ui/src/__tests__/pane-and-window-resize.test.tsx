import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from '../App';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import {
  COLLAPSED_SIDEBAR_WIDTH,
  DEFAULT_INSPECTOR_WIDTH,
  DEFAULT_SIDEBAR_WIDTH,
  INSPECTOR_WIDTH_STORAGE_KEY,
  MAX_INSPECTOR_WIDTH,
  MAX_SIDEBAR_WIDTH,
  MIN_CENTER_WORKSPACE_WIDTH,
  MIN_INSPECTOR_WIDTH,
  MIN_SIDEBAR_WIDTH,
  SIDEBAR_WIDTH_STORAGE_KEY,
  clampInspectorWidth,
  clampSidebarWidth,
  resolveEffectivePaneWidths,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../stores';

describe('Resizable Sidebar & Inspector Panes + 8-Direction Window Resize (v1.2.2)', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    localStorage.clear();
    mock = new InMemoryMockTransport();
    setTransport(mock);

    Object.defineProperty(window, 'innerWidth', {
      configurable: true,
      writable: true,
      value: 1440,
    });

    useCoordinatorStore.setState({
      destination: { type: 'allItems' },
      sidebarOpen: true,
      sidebarCollapsed: false,
      sidebarWidth: DEFAULT_SIDEBAR_WIDTH,
      inspectorOpen: true,
      inspectorWidth: DEFAULT_INSPECTOR_WIDTH,
      isResizingPane: null,
      windowMaximized: false,
      quickLookAssetId: null,
      quickLookOriginRect: null,
      settingsOpen: false,
      jumpOpen: false,
      captureOpen: false,
      onboardingOpen: false,
      onboardingDone: true,
      moodboardGeneratorOpen: false,
      selectedAssetIds: [],
      lastSelectedAssetId: null,
    });
    useLibraryStore.setState({
      assets: [],
      allAssets: [],
      folders: [],
      smartFolders: [],
      tagCounts: [],
      inboxCount: 0,
      bootstrapped: false,
    });
    useMoodboardStore.setState({ boards: [], activeBoard: null });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it('clamps Sidebar and Inspector widths deterministically and preserves >= 360px center workspace', () => {
    // Hard bounds & NaN guards
    expect(clampSidebarWidth(100)).toBe(MIN_SIDEBAR_WIDTH);
    expect(clampSidebarWidth(900)).toBe(MAX_SIDEBAR_WIDTH);
    expect(clampSidebarWidth(Number.NaN)).toBe(DEFAULT_SIDEBAR_WIDTH);
    expect(clampSidebarWidth(Number.POSITIVE_INFINITY)).toBe(DEFAULT_SIDEBAR_WIDTH);

    expect(clampInspectorWidth(120)).toBe(MIN_INSPECTOR_WIDTH);
    expect(clampInspectorWidth(900)).toBe(MAX_INSPECTOR_WIDTH);
    expect(clampInspectorWidth(Number.NaN)).toBe(DEFAULT_INSPECTOR_WIDTH);

    // Narrow 960px window with 300px Inspector: Sidebar max = 960 - 360 - 300 = 300
    expect(clampSidebarWidth(420, 960, true, 300)).toBe(300);
    // Narrow 960px window with 232px Sidebar: Inspector max = 960 - 360 - 232 = 368
    expect(clampInspectorWidth(480, 960, 232)).toBe(368);

    // Mutual clamping leaves at least MIN_CENTER_WORKSPACE_WIDTH (360px)
    const mutual = resolveEffectivePaneWidths({
      windowWidth: 1000,
      sidebarOpen: true,
      sidebarCollapsed: false,
      sidebarWidth: 420,
      inspectorOpen: true,
      inspectorWidth: 480,
    });
    expect(mutual.sidebarEffectiveWidth).toBeGreaterThanOrEqual(MIN_SIDEBAR_WIDTH);
    expect(mutual.inspectorEffectiveWidth).toBeGreaterThanOrEqual(MIN_INSPECTOR_WIDTH);
    expect(1000 - mutual.sidebarEffectiveWidth - mutual.inspectorEffectiveWidth).toBeGreaterThanOrEqual(
      MIN_CENTER_WORKSPACE_WIDTH,
    );

    // Collapsed rail occupies exactly 76px
    const collapsed = resolveEffectivePaneWidths({
      windowWidth: 1200,
      sidebarOpen: true,
      sidebarCollapsed: true,
      sidebarWidth: 320,
      inspectorOpen: true,
      inspectorWidth: 340,
    });
    expect(collapsed.sidebarEffectiveWidth).toBe(COLLAPSED_SIDEBAR_WIDTH);
    expect(collapsed.inspectorEffectiveWidth).toBe(340);
  });

  it('drags Sidebar divider with commit-on-pointerup persistence, double-click reset, and collapsed rail drag-to-expand', async () => {
    const setItemSpy = vi.spyOn(Storage.prototype, 'setItem');
    render(<App />);
    await waitFor(() => {
      expect(screen.getByTestId('gallery-stage')).toBeInTheDocument();
    });

    const divider = screen.getByTestId('sidebar-resize-divider');
    expect(screen.getByTestId('sidebar-slot').style.width).toBe(`${DEFAULT_SIDEBAR_WIDTH}px`);

    // Drag right by +68px -> 300px live, NO localStorage writes during move
    fireEvent.pointerDown(divider, { button: 0, pointerId: 1, clientX: 232 });
    fireEvent.pointerMove(divider, { pointerId: 1, clientX: 300 });
    expect(useCoordinatorStore.getState().sidebarWidth).toBe(300);
    expect(screen.getByTestId('sidebar-slot').style.width).toBe('300px');
    expect(
      setItemSpy.mock.calls.filter(([k]) => k === SIDEBAR_WIDTH_STORAGE_KEY),
    ).toHaveLength(0);

    // Release commits ONCE to localStorage
    fireEvent.pointerUp(divider, { pointerId: 1, clientX: 300 });
    expect(localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY)).toBe('300');

    // Double-click resets cleanly back to 232px
    fireEvent.doubleClick(divider);
    expect(useCoordinatorStore.getState().sidebarWidth).toBe(DEFAULT_SIDEBAR_WIDTH);
    expect(localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY)).toBe(String(DEFAULT_SIDEBAR_WIDTH));

    // Collapse to 76px rail -> dragging right >= 40px expands smoothly
    useCoordinatorStore.getState().setSidebarCollapsed(true);
    await waitFor(() => {
      expect(screen.getByTestId('sidebar-slot').style.width).toBe(`${COLLAPSED_SIDEBAR_WIDTH}px`);
    });
    const collapsedDivider = screen.getByTestId('sidebar-resize-divider');
    fireEvent.pointerDown(collapsedDivider, { button: 0, pointerId: 2, clientX: 76 });
    fireEvent.pointerMove(collapsedDivider, { pointerId: 2, clientX: 100 }); // +24px < 40px -> stays collapsed
    expect(useCoordinatorStore.getState().sidebarCollapsed).toBe(true);
    fireEvent.pointerMove(collapsedDivider, { pointerId: 2, clientX: 200 }); // +124px >= 40px -> expands!
    expect(useCoordinatorStore.getState().sidebarCollapsed).toBe(false);
    fireEvent.pointerUp(collapsedDivider, { pointerId: 2, clientX: 200 });
    expect(useCoordinatorStore.getState().sidebarWidth).toBe(200);
  });

  it('syncs draggable Inspector width 1:1 between Main Workspace and Quick Look', async () => {
    render(<App />);
    await waitFor(() => {
      expect(useLibraryStore.getState().assets.length).toBeGreaterThan(0);
    });

    // Resize Main Inspector leftward by 60px -> 360px
    const mainDivider = screen.getByTestId('inspector-resize-divider');
    fireEvent.pointerDown(mainDivider, { button: 0, pointerId: 3, clientX: 1140 });
    fireEvent.pointerMove(mainDivider, { pointerId: 3, clientX: 1080 });
    fireEvent.pointerUp(mainDivider, { pointerId: 3, clientX: 1080 });
    expect(useCoordinatorStore.getState().inspectorWidth).toBe(360);
    expect(screen.getByTestId('main-inspector-slot').style.width).toBe('360px');
    expect(localStorage.getItem(INSPECTOR_WIDTH_STORAGE_KEY)).toBe('360');

    // Open Quick Look -> Inspector inherits 360px 1:1
    const firstId = useLibraryStore.getState().assets[0].id;
    useCoordinatorStore.getState().openQuickLook(firstId);
    await waitFor(() => {
      expect(screen.getByTestId('quicklook-inspector-slot')).toBeInTheDocument();
    });
    expect(screen.getByTestId('quicklook-inspector-slot').style.width).toBe('360px');

    // Drag Quick Look Inspector divider leftward by 50px -> 410px, reflected back in Main Workspace!
    const qlDivider = screen.getByTestId('quicklook-inspector-resize-divider');
    fireEvent.pointerDown(qlDivider, { button: 0, pointerId: 4, clientX: 1080 });
    fireEvent.pointerMove(qlDivider, { pointerId: 4, clientX: 1030 });
    fireEvent.pointerUp(qlDivider, { pointerId: 4, clientX: 1030 });

    expect(useCoordinatorStore.getState().inspectorWidth).toBe(410);
    expect(screen.getByTestId('quicklook-inspector-slot').style.width).toBe('410px');
    expect(screen.getByTestId('main-inspector-slot').style.width).toBe('410px');
    expect(localStorage.getItem(INSPECTOR_WIDTH_STORAGE_KEY)).toBe('410');

    // Double-click in Quick Look resets both to 300px
    fireEvent.doubleClick(qlDivider);
    expect(useCoordinatorStore.getState().inspectorWidth).toBe(DEFAULT_INSPECTOR_WIDTH);
    expect(screen.getByTestId('quicklook-inspector-slot').style.width).toBe('300px');
    expect(screen.getByTestId('main-inspector-slot').style.width).toBe('300px');
  });

  it('renders 8-direction native resize strips (including West & East horizontal edges) when restored and hides them when maximized', async () => {
    render(<App />);
    await waitFor(() => {
      expect(screen.getByTestId('gallery-stage')).toBeInTheDocument();
    });

    const directions = [
      'West',
      'East',
      'North',
      'South',
      'NorthWest',
      'NorthEast',
      'SouthWest',
      'SouthEast',
    ] as const;

    for (const dir of directions) {
      const strip = screen.getByTestId(`window-resize-${dir}`);
      expect(strip).toBeInTheDocument();
      fireEvent.pointerDown(strip, { button: 0 });
      expect(mock.lastWindowResizeDirection).toBe(dir);
    }

    // Maximized window hides all edge strips so Fitts's Law top-right Close stays 100% unobstructed
    useCoordinatorStore.getState().setWindowMaximized(true);
    await waitFor(() => {
      expect(screen.queryByTestId('window-resize-East')).toBeNull();
      expect(screen.queryByTestId('window-resize-West')).toBeNull();
    });
  });
});
