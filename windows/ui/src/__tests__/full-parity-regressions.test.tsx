/// <reference types="vite/client" />
import React from 'react';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from '../App';
import {
  InMemoryMockTransport,
  setTransport,
  type CharkleEventHandlers,
  type CharkleTransport,
} from '../api/transport';
import {
  CharkleSlider,
  ErrorBoundary,
  LENS_DEFAULTS,
  adapt,
  getGlassTintScale,
  hexLuminance,
  hexPerceivedLuma,
  pickInk,
  setGlassTintScale,
  startLiquidGlassController,
  tintFloor,
} from '../design-system';
import { AssetCard } from '../features/gallery/AssetCard';
import { InspectorView } from '../features/inspector/InspectorView';
import { MoodboardsHome } from '../features/moodboard/MoodboardsHome';
import { SettingsOverlay } from '../features/settings/SettingsOverlay';
import { TopEdgeDropShelf } from '../features/shelf/TopEdgeDropShelf';

async function loadTokensCss(): Promise<string> {
  const fsSpec = 'node:fs';
  const pathSpec = 'node:path';
  const fs = (await import(/* @vite-ignore */ fsSpec)) as {
    readFileSync: (filePath: string, encoding: 'utf8') => string;
  };
  const path = (await import(/* @vite-ignore */ pathSpec)) as {
    resolve: (...segments: string[]) => string;
  };
  const cwd = (globalThis as { process?: { cwd: () => string } }).process?.cwd() ?? '.';
  return fs.readFileSync(path.resolve(cwd, 'src/design-system/tokens.css'), 'utf8');
}
import {
  DEFAULT_INSPECTOR_CARD_ORDER,
  normalizeMoodboardDocument,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  useSyncAIStore,
  type InspectorCardId,
} from '../stores';
import {
  createDefaultFilterCriteria,
  type AssetRecord,
  type GroupTint,
  type MoodboardDocument,
  type NoteStyle,
} from '../types/domain';

function resetAllStores() {
  useCoordinatorStore.setState({
    themeMode: 'light',
    surfaceState: null,
    sidebarOpen: true,
    sidebarCollapsed: false,
    inspectorOpen: true,
    inspectorTab: 'info',
    inspectorCardOrder: [...DEFAULT_INSPECTOR_CARD_ORDER],
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
    onboardingStep: 0,
    resumeOnboardingOnSettingsClose: false,
    moodboardGeneratorOpen: false,
    activeMoodboardId: null,
    toasts: [],
  });
  useLibraryStore.setState({
    assets: [],
    allAssets: [],
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
    curating: false,
  });
  useSyncAIStore.setState({
    syncConfig: null,
    syncStatus: null,
    cacheStats: null,
    syncing: false,
    migrating: false,
    aiState: null,
    typesafeState: null,
    agentState: null,
    diagnostics: null,
  });
}

function makeAsset(overrides: Partial<AssetRecord>): AssetRecord {
  return {
    id: '90000000-0000-4000-8000-000000000001',
    contentHash: 'hash-test',
    mediaKind: 'image',
    mimeType: 'image/png',
    title: '测试素材',
    fileName: 'sample.png',
    notes: '',
    tags: ['建筑'],
    suggestedTags: ['温暖'],
    rating: 4,
    pixelWidth: 1600,
    pixelHeight: 900,
    fileSizeBytes: 256_000,
    dominantColors: [{ hex: '#D4A373', l: 70, a: 12, b: 30, proportion: 0.6 }],
    waveformPeaks: [],
    pinnedOffline: false,
    isLocalOriginalCached: true,
    isTrashed: false,
    createdAt: 0,
    updatedAt: 0,
    updatedHLC: 1,
    ...overrides,
  };
}

describe('Full macOS Parity Regressions (Inspector, Onboarding, Gallery Glass, Moodboard, Drop Shelf)', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    localStorage.clear();
    document.documentElement.removeAttribute('data-backdrop');
    mock = new InMemoryMockTransport(true);
    setTransport(mock);
    resetAllStores();
  });

  // -------------------------------------------------------------------------
  // 1. Inspector Uncropped Proportional Preview + Card Reorder (Up & Down)
  // -------------------------------------------------------------------------

  it('renders Inspector uncropped proportional preview (portrait & landscape) with object-contain and exact macOS math', () => {
    // Portrait: 800 x 2000 -> ratio = 0.4, fittedHeight = min(280, max(108, round(252/0.4))) = 280, fittedWidth = min(252, round(280*0.4)) = 112
    const portrait = makeAsset({
      id: '90000000-0000-4000-8000-000000000011',
      title: 'Portrait Poster',
      pixelWidth: 800,
      pixelHeight: 2000,
    });
    const { rerender } = render(<InspectorView pinnedAsset={portrait} />);
    const portraitImg = screen.getByAltText('Portrait Poster');
    expect(portraitImg).toHaveClass('object-contain');
    const portraitBtn = portraitImg.closest('button') as HTMLButtonElement;
    expect(portraitBtn.style.width).toBe('112px');
    expect(portraitBtn.style.height).toBe('280px');

    // Landscape: 1600 x 900 -> ratio = 1.7778, fittedHeight = round(252/1.7778) = 142, fittedWidth = min(252, round(142*1.7778)) = 252
    const landscape = makeAsset({
      id: '90000000-0000-4000-8000-000000000012',
      title: 'Landscape Frame',
      pixelWidth: 1600,
      pixelHeight: 900,
    });
    rerender(<InspectorView pinnedAsset={landscape} isQuickLookHosted={true} />);
    const landscapeImg = screen.getByAltText('Landscape Frame');
    expect(landscapeImg).toHaveClass('object-contain');
    const landscapeBtn = landscapeImg.closest('button') as HTMLButtonElement;
    expect(landscapeBtn.style.width).toBe('252px');
    expect(landscapeBtn.style.height).toBe('142px');
  });

  it('reorders Inspector cards cleanly both downward and upward with zero off-by-one bug & persists reset', () => {
    const store = useCoordinatorStore.getState();
    expect(store.inspectorCardOrder).toEqual(DEFAULT_INSPECTOR_CARD_ORDER);

    // Downward move: index 0 ('previewIdentity') -> target index 2 ('colorsAndTags')
    store.moveInspectorCard('previewIdentity', 'colorsAndTags');
    expect(useCoordinatorStore.getState().inspectorCardOrder.slice(0, 4)).toEqual([
      'quickActions',
      'colorsAndTags',
      'previewIdentity',
      'notesAndOCR',
    ]);

    // Upward move: index 3 ('notesAndOCR') -> target index 0 ('quickActions')
    useCoordinatorStore.getState().moveInspectorCard('notesAndOCR', 'quickActions');
    expect(useCoordinatorStore.getState().inspectorCardOrder.slice(0, 4)).toEqual([
      'notesAndOCR',
      'quickActions',
      'colorsAndTags',
      'previewIdentity',
    ]);

    // Step down & step up across visible cards
    const visible: InspectorCardId[] = [
      'notesAndOCR',
      'quickActions',
      'colorsAndTags',
      'previewIdentity',
      'mediaSpecs',
    ];
    useCoordinatorStore.getState().stepInspectorCard('quickActions', 1, visible);
    expect(useCoordinatorStore.getState().inspectorCardOrder.slice(0, 4)).toEqual([
      'notesAndOCR',
      'colorsAndTags',
      'quickActions',
      'previewIdentity',
    ]);
    useCoordinatorStore
      .getState()
      .stepInspectorCard('quickActions', -1, [
        'notesAndOCR',
        'colorsAndTags',
        'quickActions',
        'previewIdentity',
        'mediaSpecs',
      ]);
    expect(useCoordinatorStore.getState().inspectorCardOrder.slice(0, 4)).toEqual([
      'notesAndOCR',
      'quickActions',
      'colorsAndTags',
      'previewIdentity',
    ]);

    // Move to top / bottom & reset
    useCoordinatorStore.getState().moveInspectorCardToTop('mediaSpecs');
    expect(useCoordinatorStore.getState().inspectorCardOrder[0]).toBe('mediaSpecs');

    useCoordinatorStore.getState().moveInspectorCardToBottom('mediaSpecs');
    const order = useCoordinatorStore.getState().inspectorCardOrder;
    expect(order[order.length - 1]).toBe('mediaSpecs');

    useCoordinatorStore.getState().resetInspectorCardOrder();
    expect(useCoordinatorStore.getState().inspectorCardOrder).toEqual(DEFAULT_INSPECTOR_CARD_ORDER);
  });

  it('supports right-click Inspector header menu & bottom reset capsule when order is customized', async () => {
    const asset = makeAsset({});
    render(<InspectorView pinnedAsset={asset} />);

    // Right-click "色板与标签" header and move to top
    const colorsCard = document.querySelector('[data-inspector-card="colorsAndTags"]')!;
    const header = colorsCard.firstElementChild as HTMLElement;
    fireEvent.contextMenu(header, { clientX: 120, clientY: 160 });

    const topBtn = await screen.findByRole('button', { name: /移到最顶部/ });
    fireEvent.click(topBtn);

    expect(useCoordinatorStore.getState().inspectorCardOrder[0]).toBe('colorsAndTags');

    const resetBtn = await screen.findByRole('button', { name: /恢复信息栏默认排序/ });
    fireEvent.click(resetBtn);
    expect(useCoordinatorStore.getState().inspectorCardOrder).toEqual(DEFAULT_INSPECTOR_CARD_ORDER);
  });

  // -------------------------------------------------------------------------
  // 2. Onboarding Non-Destructive Settings Handoff & Exact-Step Resume
  // -------------------------------------------------------------------------

  it('preserves Onboarding at exact step across openSettingsFromOnboarding -> 返回继续引导 -> closeSettings', async () => {
    useCoordinatorStore.setState({ onboardingDone: false });
    render(<App />);

    await act(async () => {
      useCoordinatorStore.getState().openOnboarding();
    });

    await waitFor(() => {
      expect(screen.getByTestId('onboarding-studio')).toBeInTheDocument();
    });

    // Advance from Step 0 -> Step 1 (Library / Cloud Sync)
    fireEvent.click(screen.getByRole('button', { name: /开始快速配置/ }));
    expect(useCoordinatorStore.getState().onboardingStep).toBe(1);
    expect(screen.getByText(/素材库保存在哪里？/)).toBeInTheDocument();

    // Select Google Drive and jump to Settings -> Sync via non-destructive handoff
    fireEvent.click(screen.getByText('Google Drive 云端直连'));
    const goSyncBtn = await screen.findByRole('button', { name: /前往配置云同步/ });
    fireEvent.click(goSyncBtn);

    await waitFor(() => {
      expect(screen.getByTestId('settings-overlay')).toBeInTheDocument();
      expect(screen.getByTestId('settings-pane-sync')).toBeInTheDocument();
      expect(screen.getByTestId('settings-return-onboarding')).toBeInTheDocument();
    });

    // Onboarding MUST NOT be marked completed mid-flow
    expect(useCoordinatorStore.getState().onboardingDone).toBe(false);
    expect(useCoordinatorStore.getState().resumeOnboardingOnSettingsClose).toBe(true);
    expect(useCoordinatorStore.getState().onboardingStep).toBe(1);

    // Open a nested sub-modal inside Settings and press Escape: ONLY the sub-modal closes!
    fireEvent.click(screen.getByRole('button', { name: /更改或转移…/ }));
    await waitFor(() => {
      expect(screen.getByText('更改或转移素材库位置')).toBeInTheDocument();
    });
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => {
      expect(screen.queryByText('更改或转移素材库位置')).not.toBeInTheDocument();
    });
    expect(screen.getByTestId('settings-overlay')).toBeInTheDocument();

    // Click "返回继续引导" -> returns directly to Onboarding Step 1!
    fireEvent.click(screen.getByTestId('settings-return-onboarding'));
    await waitFor(() => {
      expect(screen.getByTestId('onboarding-studio')).toBeInTheDocument();
      expect(screen.getByText(/素材库保存在哪里？/)).toBeInTheDocument();
    });
    expect(useCoordinatorStore.getState().onboardingStep).toBe(1);
    expect(useCoordinatorStore.getState().onboardingDone).toBe(false);
  });

  // -------------------------------------------------------------------------
  // 3. Gallery Floating Liquid Glass (Zero Scroll-Fade Veil, Zero solidFallback Kill-Switch, ErrorBoundary)
  // -------------------------------------------------------------------------

  it('renders floating .charkle-glass top capsules with zero .charkle-scroll-fade-top veil and no solidFallback glass kill-switch', async () => {
    document.documentElement.dataset.backdrop = 'solidFallback';
    render(<App />);

    await waitFor(() => {
      expect(screen.getByTestId('gallery-stage')).toBeInTheDocument();
    });

    const stage = screen.getByTestId('gallery-stage');
    expect(stage.querySelector('.charkle-scroll-fade-top')).toBeNull();

    const glassCapsules = stage.querySelectorAll('.charkle-glass');
    expect(glassCapsules.length).toBeGreaterThanOrEqual(4);

    // Confirm tokens.css never kills .charkle-glass under data-backdrop="solidFallback"
    const tokensCss = await loadTokensCss();
    expect(tokensCss.length).toBeGreaterThan(5000);
    expect(tokensCss).not.toMatch(/charkle-scroll-fade-top/);
    expect(tokensCss).not.toMatch(/\[data-backdrop="solidFallback"\]\s+\.charkle-glass/);

    // Confirm startLiquidGlassController starts cleanly even when data-backdrop="solidFallback"
    const stopGlass = startLiquidGlassController({ rim: 34, edge: 1.1, power: 2.6, dispersion: 0.16 });
    expect(typeof stopGlass).toBe('function');
    stopGlass();

    // Confirm ErrorBoundary catches runtime errors cleanly with recovery UI
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const Bomb: React.FC = () => {
      throw new Error('simulated crash');
    };
    render(
      <ErrorBoundary title="测试崩溃恢复">
        <Bomb />
      </ErrorBoundary>,
    );
    expect(screen.getByRole('alert')).toBeInTheDocument();
    expect(screen.getByText('测试崩溃恢复')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /重新加载界面/ })).toBeInTheDocument();
    spy.mockRestore();
  });

  // -------------------------------------------------------------------------
  // 4. Moodboard Freeform Drag/Resize/Rotate/Eraser + Defensive Unknown Tint & Empty Arrays
  // -------------------------------------------------------------------------

  it('survives unknown group tint, unknown note style, null optional arrays, and Freeform drag/resize/rotate/eraser without throwing', async () => {
    // Normalize malformed document with null optional arrays
    const malformed = normalizeMoodboardDocument({
      id: '80000000-0000-4000-8000-000000000099',
      title: '防御测试情绪板',
      subtitle: '',
      mode: { freeform: {} },
      nodes: [
        {
          id: '81000000-0000-4000-8000-000000000001',
          kind: {
            groupFrame: {
              title: '未知色调分组',
              tint: 'mysteryTint' as GroupTint,
            },
          },
          frame: { x: 80, y: 80, width: 320, height: 240 },
          zIndex: 0,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 0,
          updatedAt: 0,
        },
        {
          id: '81000000-0000-4000-8000-000000000002',
          kind: {
            note: {
              title: '未知样式便签',
              text: '不会崩溃',
              style: 'mysteryNote' as NoteStyle,
              fontSize: 14,
            },
          },
          frame: { x: 460, y: 120, width: 220, height: 140 },
          zIndex: 1,
          rotationDegrees: 15,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 1,
          updatedAt: 0,
        },
      ],
      connectors: undefined as unknown as MoodboardDocument['connectors'],
      inkStrokes: undefined as unknown as MoodboardDocument['inkStrokes'],
      extractedPalette: undefined as unknown as MoodboardDocument['extractedPalette'],
      candidateAssetIDs: undefined as unknown as MoodboardDocument['candidateAssetIDs'],
      pinnedOffline: false,
      viewportCenter: { x: 320, y: 200 },
      viewportZoom: 1,
      createdAt: 0,
      updatedAt: 0,
      updatedHLC: 1,
    });
    expect(malformed.connectors).toEqual([]);
    expect(malformed.inkStrokes).toEqual([]);
    expect(malformed.extractedPalette).toEqual([]);
    expect(malformed.candidateAssetIDs).toEqual([]);

    await mock.saveBoard(malformed);
    render(<App />);

    await act(async () => {
      await useMoodboardStore.getState().openBoard(malformed.id);
      useCoordinatorStore.getState().setDestination({ type: 'moodboard', id: malformed.id });
    });

    await waitFor(() => {
      expect(screen.getByTestId('moodboard-studio-view')).toBeInTheDocument();
      expect(screen.getByText('未知色调分组')).toBeInTheDocument();
      expect(screen.getByText('不会崩溃')).toBeInTheDocument();
    });

    // Freeform drag commits once on mouseup without mid-drag save flood
    const saveSpy = vi.spyOn(mock, 'saveBoard');
    const noteNodeId = '81000000-0000-4000-8000-000000000002';
    const noteEl = document.querySelector(`[data-board-node-id="${noteNodeId}"]`)!;
    const beforeFrame = {
      ...useMoodboardStore.getState().activeBoard!.nodes.find((n) => n.id === noteNodeId)!.frame,
    };

    fireEvent.mouseDown(noteEl, { button: 0, clientX: 500, clientY: 160 });
    fireEvent.mouseMove(window, { clientX: 540, clientY: 190 });
    fireEvent.mouseMove(window, { clientX: 580, clientY: 220 });
    expect(saveSpy).not.toHaveBeenCalled();
    fireEvent.mouseUp(window, { clientX: 580, clientY: 220 });

    const afterDrag = useMoodboardStore
      .getState()
      .activeBoard!.nodes.find((n) => n.id === noteNodeId)!.frame;
    expect(afterDrag.x).toBeGreaterThan(beforeFrame.x);
    expect(afterDrag.y).toBeGreaterThan(beforeFrame.y);

    // Rotation knob double-click resets angle to 0°
    const rotateHandle = screen.getByTestId('rotation-handle');
    fireEvent.doubleClick(rotateHandle);
    expect(
      useMoodboardStore.getState().activeBoard!.nodes.find((n) => n.id === noteNodeId)!
        .rotationDegrees,
    ).toBe(0);

    // Corner resize handle resizes smoothly on pointer drag + release
    const resizeHandle = screen.getByTestId('resize-handle-bottomTrailing');
    const preResizeW = afterDrag.width;
    fireEvent.pointerDown(resizeHandle, { button: 0, clientX: 600, clientY: 300 });
    fireEvent.pointerMove(window, { clientX: 660, clientY: 340 });
    fireEvent.pointerUp(window, { clientX: 660, clientY: 340 });
    const postResize = useMoodboardStore
      .getState()
      .activeBoard!.nodes.find((n) => n.id === noteNodeId)!.frame;
    expect(postResize.width).toBeGreaterThan(preResizeW);

    // Draw an ink stroke then erase it with Eraser tool ('E')
    fireEvent.click(screen.getByRole('button', { name: '画笔工具' }));
    const stage = screen.getByTestId('moodboard-canvas-stage');
    fireEvent.mouseDown(stage, { button: 0, clientX: 200, clientY: 200 });
    fireEvent.mouseMove(window, { clientX: 260, clientY: 240 });
    fireEvent.mouseUp(window, { clientX: 260, clientY: 240 });
    expect(useMoodboardStore.getState().activeBoard!.inkStrokes.length).toBeGreaterThanOrEqual(1);

    fireEvent.keyDown(window, { key: 'e' });
    fireEvent.mouseDown(stage, { button: 0, clientX: 200, clientY: 200 });
    fireEvent.mouseMove(window, { clientX: 260, clientY: 240 });
    fireEvent.mouseUp(window, { clientX: 260, clientY: 240 });
    expect(useMoodboardStore.getState().activeBoard!.inkStrokes.length).toBe(0);
  });

  // -------------------------------------------------------------------------
  // 5. Top-Edge Drop Shelf Target Persistence, Hit-Rect & Drop Status
  // -------------------------------------------------------------------------

  it('persists TopEdgeDropShelf target mode, reports full expanded hit-rect (never 228x36), and handles shelf:drop-status', async () => {
    let capturedHandlers: CharkleEventHandlers | null = null;
    const transportObj: CharkleTransport = mock;
    vi.spyOn(transportObj, 'subscribeEvents').mockImplementation(
      async (handlers: CharkleEventHandlers) => {
        capturedHandlers = handlers;
        return () => {};
      },
    );

    render(<TopEdgeDropShelf initialExpanded={true} />);

    await waitFor(() => {
      expect(screen.getByTestId('top-edge-drop-shelf')).toHaveAttribute('data-expanded', 'true');
      expect(mock.lastShelfHitRect).not.toBeNull();
    });

    // Hit rect MUST cover full compact capsule (never collapsed 228x36)
    expect(mock.lastShelfHitRect!.width).toBeGreaterThanOrEqual(600);
    expect(mock.lastShelfHitRect!.height).toBeGreaterThanOrEqual(300);

    // Switching target persists via saveShelfSettings
    fireEvent.click(screen.getByRole('radio', { name: '活跃情绪板' }));
    await waitFor(async () => {
      const saved = await mock.getShelfSettings();
      expect(saved.defaultTargetMode).toBe('activeMoodboard');
    });

    // shelf:drop-status processing -> done confirmation banner in Compact Drop Well
    expect(capturedHandlers).not.toBeNull();
    act(() => {
      capturedHandlers!.onShelfDropStatus?.({
        phase: 'processing',
        message: '正在收藏 2 项素材…',
      });
    });
    expect(screen.getByText('正在收藏 2 项素材…')).toBeInTheDocument();

    act(() => {
      capturedHandlers!.onShelfDropStatus?.({
        phase: 'done',
        message: '已收入「收件箱」(2 项)',
      });
    });
    await waitFor(() => {
      expect(screen.getByText('已收入「收件箱」(2 项)')).toBeInTheDocument();
    });

    // Expanding to Full-Waterfall widens hit-rect further
    fireEvent.click(screen.getByRole('button', { name: '展开为全瀑布流抽屉' }));
    await waitFor(() => {
      expect(mock.lastShelfHitRect!.width).toBeGreaterThanOrEqual(900);
      expect(mock.lastShelfHitRect!.height).toBeGreaterThanOrEqual(500);
    });
  });

  // -------------------------------------------------------------------------
  // 6. Bespoke CharkleSlider (Pointer Drag, Keyboard Nav, Disabled, Zero Raw Range)
  // -------------------------------------------------------------------------

  it('drives CharkleSlider via pointer drag and keyboard navigation with zero raw range inputs in Gallery', async () => {
    const onChange = vi.fn();
    const onChangeEnd = vi.fn();

    const ControlledSliderHarness: React.FC<{
      disabled?: boolean;
      variant?: 'glass' | 'standard';
      size?: 'sm' | 'md';
    }> = ({ disabled = false, variant = 'glass', size = 'sm' }) => {
      const [val, setVal] = React.useState(200);
      return (
        <CharkleSlider
          min={100}
          max={400}
          step={10}
          value={val}
          onChange={(next) => {
            setVal(next);
            onChange(next);
          }}
          onChangeEnd={onChangeEnd}
          ariaLabel="测试缩放滑块"
          variant={variant}
          size={size}
          disabled={disabled}
          valueText={`${val} px`}
          data-testid="test-glass-slider"
        />
      );
    };

    const { rerender } = render(<ControlledSliderHarness />);

    const slider = screen.getByTestId('test-glass-slider');
    expect(slider).toHaveAttribute('role', 'slider');
    expect(slider).toHaveAttribute('data-variant', 'glass');
    expect(slider).toHaveAttribute('aria-valuenow', '200');
    expect(slider).toHaveAttribute('aria-valuetext', '200 px');

    // Mock bounding box (200px wide, starting at left=100; glass sm thumbHalf=9 -> usable=182px)
    vi.spyOn(slider, 'getBoundingClientRect').mockReturnValue({
      left: 100,
      top: 0,
      right: 300,
      bottom: 22,
      width: 200,
      height: 22,
      x: 100,
      y: 0,
      toJSON: () => ({}),
    });

    // Pointer drag toward the right edge updates value cleanly and commits on pointerUp
    fireEvent.pointerDown(slider, { button: 0, pointerId: 1, clientX: 291 });
    expect(onChange).toHaveBeenCalledWith(400);
    expect(slider).toHaveAttribute('aria-valuenow', '400');
    fireEvent.pointerMove(slider, { pointerId: 1, clientX: 109 });
    expect(onChange).toHaveBeenCalledWith(100);
    expect(slider).toHaveAttribute('aria-valuenow', '100');
    fireEvent.pointerUp(slider, { pointerId: 1, clientX: 109 });
    expect(onChangeEnd).toHaveBeenCalledWith(100);

    // Keyboard stepping: ArrowRight (100 -> 110), End (400), ArrowLeft (390), Home (100)
    onChange.mockClear();
    onChangeEnd.mockClear();
    fireEvent.keyDown(slider, { key: 'ArrowRight' });
    expect(onChange).toHaveBeenCalledWith(110);
    expect(onChangeEnd).toHaveBeenCalledWith(110);

    fireEvent.keyDown(slider, { key: 'End' });
    expect(onChange).toHaveBeenCalledWith(400);

    fireEvent.keyDown(slider, { key: 'ArrowLeft' });
    expect(onChange).toHaveBeenCalledWith(390);

    fireEvent.keyDown(slider, { key: 'Home' });
    expect(onChange).toHaveBeenCalledWith(100);

    // Disabled state suppresses interactions
    onChange.mockClear();
    rerender(<ControlledSliderHarness disabled variant="standard" size="md" />);
    expect(slider).toHaveAttribute('aria-disabled', 'true');
    fireEvent.keyDown(slider, { key: 'ArrowRight' });
    expect(onChange).not.toHaveBeenCalled();

    // Gallery renders CharkleSlider (role="slider") and zero raw <input type="range">
    render(<App />);
    await waitFor(() => {
      expect(screen.getByTestId('gallery-stage')).toBeInTheDocument();
    });
    expect(screen.getByRole('slider', { name: '卡片缩放尺寸' })).toBeInTheDocument();
    expect(document.querySelectorAll('input[type="range"]').length).toBe(0);
  });

  // -------------------------------------------------------------------------
  // 7. Crystal-Clear Optical Liquid Glass & Adaptive Surface Tone Math
  // -------------------------------------------------------------------------

  it('keeps clear optical glass calibration and adapts ink/floor cleanly over light, dark, and midtone cards', async () => {
    expect(LENS_DEFAULTS.rim).toBeGreaterThanOrEqual(36);
    expect(LENS_DEFAULTS.edge).toBeGreaterThanOrEqual(1.2);
    expect(LENS_DEFAULTS.dispersion).toBeGreaterThan(0);

    // Pure white vs deep charcoal luminance & perceived sRGB luma
    expect(hexLuminance('#FFFFFF')).toBeCloseTo(1, 3);
    expect(hexLuminance('#000000')).toBeCloseTo(0, 3);
    expect(hexPerceivedLuma('#FFFFFF')).toBeCloseTo(1, 3);
    expect(hexPerceivedLuma('#000000')).toBeCloseTo(0, 3);

    // Warm-beige / sage pastel cards stay cleanly on Light Glass (dark ink) via perceived sRGB luma
    const sageLuma = hexPerceivedLuma('#9AB1A4')!;
    const sandLuma = hexPerceivedLuma('#B5A089')!;
    const deepDarkLuma = hexPerceivedLuma('#18221D')!;
    expect(sageLuma).toBeGreaterThan(0.6);
    expect(sandLuma).toBeGreaterThan(0.6);
    expect(deepDarkLuma).toBeLessThan(0.2);
    expect(pickInk(sageLuma, null)).toBe('dark');
    expect(pickInk(sandLuma, null)).toBe('dark');
    expect(pickInk(deepDarkLuma, 'dark')).toBe('light');

    // Light backdrop -> dark ink, hysteresis holds across 0.50 ± 0.05 band
    expect(pickInk(0.85, null)).toBe('dark');
    expect(pickInk(0.47, 'dark')).toBe('dark'); // within hysteresis (0.50 - 0.05 = 0.45)
    expect(pickInk(0.35, 'dark')).toBe('light'); // crosses below -> flips to smoky dark glass

    // Dark backdrop -> light ink, hysteresis holds until > 0.55
    expect(pickInk(0.12, null)).toBe('light');
    expect(pickInk(0.53, 'light')).toBe('light');
    expect(pickInk(0.6, 'light')).toBe('dark');

    // Clear light surface over bright background needs zero opaque floor
    expect(tintFloor(0.9, 0.02, 'dark', 1)).toBe(0);
    // Dark smoky glass over deep dark card also needs zero opaque floor
    expect(tintFloor(0.04, 0.02, 'light', 0.014)).toBe(0);
    // Midtone textured imagery lifts tintFloor strictly when raw contrast dips below WCAG 4.5:1
    const midLightInkFloor = tintFloor(0.42, 0.35, 'light', 0.014);
    expect(midLightInkFloor).toBeGreaterThan(0.5);
    expect(midLightInkFloor).toBeLessThanOrEqual(0.92);
    const darkTexturedFloor = tintFloor(0.24, 0.45, 'dark', 1);
    expect(darkTexturedFloor).toBeGreaterThan(0.05);
    expect(darkTexturedFloor).toBeLessThanOrEqual(0.92);

    // adapt() increases frost density on busier midtone textures and dampens hyper-saturation
    const calm = adapt({ luminance: 0.92, texture: 0.02, color: 0.05 }, 'dark');
    const busy = adapt({ luminance: 0.46, texture: 0.65, color: 0.95 }, 'dark');
    expect(busy.density).toBeGreaterThan(calm.density);
    expect(busy.keep).toBeLessThan(calm.keep);

    // tokens.css keeps optical clear-glass values under prefers-reduced-transparency: reduce
    const tokensCss = await loadTokensCss();
    expect(tokensCss.length).toBeGreaterThan(5000);
    expect(tokensCss).toMatch(/--m-thin:\s*0\.06/);
    expect(tokensCss).toMatch(/--m-blur:\s*2/);
    expect(tokensCss).toMatch(/\.charkle-mica-chrome/);
    expect(tokensCss).toMatch(/\.charkle-gallery-surface/);
  });

  // -------------------------------------------------------------------------
  // 8. Windows 11 Mica Transparency Prompt in General Settings
  // -------------------------------------------------------------------------

  it('shows calm zero-jargon transparency prompt when Mica is active with OS transparency disabled and opens ms-settings:colors', async () => {
    const openUrlSpy = vi.spyOn(mock, 'openExternalUrl').mockResolvedValue();

    useCoordinatorStore.setState({
      settingsOpen: true,
      settingsTab: 'general',
      surfaceState: {
        buildNumber: 26200,
        backdrop: 'mica',
        isDark: false,
        transparencyEnabled: false,
        animationsEnabled: true,
        snapLayoutsSupported: true,
      },
    });

    const { rerender } = render(<SettingsOverlay />);

    const prompt = await screen.findByTestId('settings-transparency-prompt');
    expect(prompt).toBeInTheDocument();
    // Enforce zero developer jargon in consumer Settings copy
    expect(prompt.textContent).not.toMatch(/Mica|DWM|WebView2|Win32|Acrylic/i);

    fireEvent.click(screen.getByRole('button', { name: /打开系统设置/ }));
    expect(openUrlSpy).toHaveBeenCalledWith('ms-settings:colors');

    // Hides cleanly once Windows Transparency Effects are enabled
    act(() => {
      useCoordinatorStore.setState({
        surfaceState: {
          buildNumber: 26200,
          backdrop: 'mica',
          isDark: false,
          transparencyEnabled: true,
          animationsEnabled: true,
          snapLayoutsSupported: true,
        },
      });
    });
    rerender(<SettingsOverlay />);
    expect(screen.queryByTestId('settings-transparency-prompt')).not.toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // 9. TopEdgeDropShelf URL-Only Clipboard Filter (Never Plain Text) + Dismiss
  // -------------------------------------------------------------------------

  it('hides plain clipboard text from Shelf Drop Well and shows quick-save banner ONLY for valid http(s) URLs (GitHub, X, generic web)', async () => {
    let capturedHandlers: CharkleEventHandlers | null = null;
    const transportObj: CharkleTransport = mock;
    vi.spyOn(transportObj, 'subscribeEvents').mockImplementation(
      async (handlers: CharkleEventHandlers) => {
        capturedHandlers = handlers;
        return () => {};
      },
    );
    const collectSpy = vi.spyOn(transportObj, 'collectClipboardNow').mockResolvedValue(1);

    render(<TopEdgeDropShelf initialExpanded={true} />);

    await waitFor(() => {
      expect(screen.getByTestId('top-edge-drop-shelf')).toBeInTheDocument();
      expect(capturedHandlers).not.toBeNull();
    });

    // 1. Plain English text MUST NOT hijack the Drop Well
    act(() => {
      capturedHandlers!.onClipboardChanged?.({
        kind: 'text',
        label: 'Give the cards and panels in my product a liquid',
        fileCount: 0,
        isSocialOrGithubUrl: false,
      });
    });
    expect(
      screen.queryByText(/Give the cards and panels in my product a liquid/),
    ).not.toBeInTheDocument();
    expect(
      screen.getByText(/拖入文件、整个文件夹、网页、推文或 GitHub 链接/),
    ).toBeInTheDocument();

    // 2. GitHub repo URL shows concise GitHub prompt + dismiss button
    act(() => {
      capturedHandlers!.onClipboardChanged?.({
        kind: 'url',
        label: 'tauri-apps/tauri',
        url: 'https://github.com/tauri-apps/tauri',
        fileCount: 0,
        isSocialOrGithubUrl: true,
      });
    });
    expect(
      await screen.findByText('检测到 GitHub 仓库链接 · tauri-apps/tauri'),
    ).toBeInTheDocument();

    // Clicking dismiss × hides the banner for that label
    fireEvent.click(screen.getByRole('button', { name: '忽略剪贴板链接' }));
    expect(
      screen.queryByText('检测到 GitHub 仓库链接 · tauri-apps/tauri'),
    ).not.toBeInTheDocument();

    // 3. X post URL shows tweet link prompt
    act(() => {
      capturedHandlers!.onClipboardChanged?.({
        kind: 'url',
        label: 'https://x.com/charkle/status/123456',
        url: 'https://x.com/charkle/status/123456',
        fileCount: 0,
        isSocialOrGithubUrl: true,
      });
    });
    expect(
      await screen.findByText('检测到推文链接 · x.com/charkle/status/123456'),
    ).toBeInTheDocument();

    // 4. Generic website URL shows webpage link prompt and auto-dismisses after clicking 保存
    act(() => {
      capturedHandlers!.onClipboardChanged?.({
        kind: 'url',
        label: 'https://tauri.app/start/',
        url: 'https://tauri.app/start/',
        fileCount: 0,
        isSocialOrGithubUrl: false,
      });
    });
    const webPromptBtn = await screen.findByRole('button', {
      name: /检测到剪贴板链接 · 检测到网页链接 · tauri\.app/,
    });
    expect(webPromptBtn).toBeInTheDocument();

    fireEvent.click(webPromptBtn);
    await waitFor(() => {
      expect(collectSpy).toHaveBeenCalled();
      expect(screen.queryByText('检测到网页链接 · tauri.app')).not.toBeInTheDocument();
    });
  });

  // -------------------------------------------------------------------------
  // 10. Plain webBookmark Opens Directly in Default Browser vs GitHub/X Quick Look
  // -------------------------------------------------------------------------

  it('opens plain webBookmark directly via openExternalUrl while GitHub repos and X posts open in-app Quick Look', async () => {
    const openUrlSpy = vi.spyOn(mock, 'openExternalUrl').mockResolvedValue();
    const markOpenedSpy = vi.spyOn(mock, 'markAssetOpened').mockResolvedValue(null);

    const plainBookmark = makeAsset({
      id: '90000000-0000-4000-8000-000000000071',
      mediaKind: 'webBookmark',
      mimeType: 'text/uri-list',
      title: 'Tauri Official Site',
      fileName: 'tauri.url',
      sourceURL: 'https://tauri.app/',
      sourceDomain: 'tauri.app',
      richMetadata: { textExcerpt: 'Build smaller, faster desktop apps.' },
    });

    const githubBookmark = makeAsset({
      id: '90000000-0000-4000-8000-000000000072',
      mediaKind: 'webBookmark',
      mimeType: 'text/uri-list',
      title: 'tauri-apps/tauri',
      fileName: 'tauri-repo.url',
      sourceURL: 'https://github.com/tauri-apps/tauri',
      sourceDomain: 'github.com',
      richMetadata: {
        githubRepo: {
          owner: 'tauri-apps',
          repo: 'tauri',
          fullName: 'tauri-apps/tauri',
          description: 'Desktop framework',
          language: 'Rust',
          stars: 92000,
          forks: 2800,
          topics: ['rust', 'desktop'],
          readmeMarkdown: '# Tauri',
        },
      },
    });

    const xBookmark = makeAsset({
      id: '90000000-0000-4000-8000-000000000073',
      mediaKind: 'webBookmark',
      mimeType: 'text/uri-list',
      title: 'Design Note on X',
      fileName: 'xpost.url',
      sourceURL: 'https://x.com/studio/status/999',
      sourceDomain: 'x.com',
      richMetadata: {
        socialPost: {
          platform: 'x',
          originalURL: 'https://x.com/studio/status/999',
          authorName: 'Studio',
          authorHandle: '@studio',
          bodyText: 'Optical glass experiments.',
          mediaURLs: [],
          mediaThumbnailURLs: [],
          attachments: [],
          hasVideo: false,
          likeCount: 120,
          repostCount: 15,
          replyCount: 4,
        },
      },
    });

    // 1. AssetCard double-click on plain webBookmark -> default browser, NO Quick Look
    const { rerender } = render(
      <AssetCard
        asset={plainBookmark}
        selected={true}
        orderedIds={[plainBookmark.id, githubBookmark.id, xBookmark.id]}
        width={240}
        height={180}
      />,
    );
    const plainCard = document.querySelector(`[data-asset-id="${plainBookmark.id}"]`)!;
    fireEvent.doubleClick(plainCard);
    expect(openUrlSpy).toHaveBeenCalledWith('https://tauri.app/');
    expect(markOpenedSpy).toHaveBeenCalledWith(plainBookmark.id);
    expect(useCoordinatorStore.getState().quickLookAssetId).toBeNull();

    // 2. AssetCard double-click on GitHub repo -> opens in-app Quick Look (NOT external browser)
    openUrlSpy.mockClear();
    rerender(
      <AssetCard
        asset={githubBookmark}
        selected={true}
        orderedIds={[plainBookmark.id, githubBookmark.id, xBookmark.id]}
        width={240}
        height={180}
      />,
    );
    const ghCard = document.querySelector(`[data-asset-id="${githubBookmark.id}"]`)!;
    fireEvent.doubleClick(ghCard);
    expect(openUrlSpy).not.toHaveBeenCalled();
    expect(useCoordinatorStore.getState().quickLookAssetId).toBe(githubBookmark.id);

    // 3. AssetCard double-click on X post -> opens in-app Quick Look
    useCoordinatorStore.getState().closeQuickLook();
    rerender(
      <AssetCard
        asset={xBookmark}
        selected={true}
        orderedIds={[plainBookmark.id, githubBookmark.id, xBookmark.id]}
        width={240}
        height={180}
      />,
    );
    const xCard = document.querySelector(`[data-asset-id="${xBookmark.id}"]`)!;
    fireEvent.doubleClick(xCard);
    expect(openUrlSpy).not.toHaveBeenCalled();
    expect(useCoordinatorStore.getState().quickLookAssetId).toBe(xBookmark.id);

    // 4. InspectorView for plain webBookmark exposes "在默认浏览器中打开" & preview click opens browser
    useCoordinatorStore.getState().closeQuickLook();
    openUrlSpy.mockClear();
    render(<InspectorView pinnedAsset={plainBookmark} />);
    const openBrowserBtn = screen.getByRole('button', { name: /在默认浏览器中打开/ });
    fireEvent.click(openBrowserBtn);
    expect(openUrlSpy).toHaveBeenCalledWith('https://tauri.app/');
  });

  // -------------------------------------------------------------------------
  // 11. Settings Glass Tint Sliders (--l-k / --d-k) & MoodboardsHome Adaptive Grid
  // -------------------------------------------------------------------------

  it('persists Light & Dark Liquid Glass tint sliders in Settings and renders macOS adaptive MoodboardsHome grid', async () => {
    setGlassTintScale('light', 1);
    setGlassTintScale('dark', 1);

    useCoordinatorStore.setState({
      settingsOpen: true,
      settingsTab: 'general',
    });

    render(<SettingsOverlay />);

    expect(await screen.findByTestId('settings-glass-tint-controls')).toBeInTheDocument();
    const lightSlider = screen.getByTestId('slider-light-glass-tint');
    const darkSlider = screen.getByTestId('slider-dark-glass-tint');

    // Step Light glass tint up (+5%) and Dark glass tint down (-5%) via keyboard
    fireEvent.keyDown(lightSlider, { key: 'ArrowRight' });
    fireEvent.keyDown(darkSlider, { key: 'ArrowLeft' });

    expect(getGlassTintScale('light')).toBeCloseTo(1.05, 2);
    expect(getGlassTintScale('dark')).toBeCloseTo(0.95, 2);
    expect(document.documentElement.style.getPropertyValue('--l-k')).toBe('1.05');
    expect(document.documentElement.style.getPropertyValue('--d-k')).toBe('0.95');

    // Clicking "重置" restores both scales cleanly to 1.0
    const resetTintBtn = await screen.findByRole('button', { name: '重置' });
    fireEvent.click(resetTintBtn);
    expect(getGlassTintScale('light')).toBe(1);
    expect(getGlassTintScale('dark')).toBe(1);

    // Confirm tokens.css includes radial inner-light ::before, --l-k / --d-k tokens,
    // and keeps default position: relative strictly inside @layer components so Tailwind v4
    // @layer utilities (absolute / fixed / sticky) ALWAYS wins on floating glass overlays.
    const tokensCss = await loadTokensCss();
    expect(tokensCss).toMatch(/\.charkle-glass::before/);
    expect(tokensCss).toMatch(/--l-k/);
    expect(tokensCss).toMatch(/--d-k/);
    expect(tokensCss).toMatch(
      /@layer\s+components\s*\{[\s\S]*?\.charkle-glass[\s\S]*?\.charkle-glass-dark[\s\S]*?position:\s*relative/,
    );
    const cssWithoutLayerComponents = tokensCss
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/@layer\s+components\s*\{[\s\S]*?\n\}/g, '');
    expect(cssWithoutLayerComponents).not.toMatch(/position:\s*relative/);

    // Confirm MoodboardsHome uses macOS adaptive card width (260px..310px, never full-width pancake)
    useMoodboardStore.setState({
      boards: [
        {
          id: 'b-home-1',
          title: '光、纸与泥',
          subtitle: 'editorial',
          mode: { freeform: {} },
          itemCount: 4,
          previewAssetIDs: ['a1', 'a2', 'a3', 'a4'],
          paletteHexes: ['#D4A373', '#2E3A2F'],
          pinnedOffline: false,
          updatedAt: 0,
        },
      ],
    });
    const { container } = render(<MoodboardsHome />);
    const gridEl = container.querySelector('.grid.gap-4') as HTMLElement | null;
    expect(gridEl).not.toBeNull();
    expect(gridEl!.style.gridTemplateColumns).toContain('minmax(260px, 310px)');
  });

  // -------------------------------------------------------------------------
  // 12. Moodboard paletteStrip, note & groupFrame Selection, Drag, Context Menu, Edit & Delete
  // -------------------------------------------------------------------------

  it('selects, drags, right-clicks, inline-edits, and deletes paletteStrip, note, and groupFrame nodes cleanly', async () => {
    const board: MoodboardDocument = {
      id: '80000000-0000-4000-8000-000000000120',
      title: '节点交互回归测试板',
      subtitle: '',
      mode: { freeform: {} },
      nodes: [],
      connectors: [],
      inkStrokes: [],
      extractedPalette: [
        { hex: '#D4A373', l: 70, a: 12, b: 30, proportion: 0.5 },
        { hex: '#2E3A2F', l: 25, a: -8, b: 6, proportion: 0.5 },
      ],
      candidateAssetIDs: [],
      pinnedOffline: false,
      viewportCenter: { x: 400, y: 300 },
      viewportZoom: 1,
      createdAt: 0,
      updatedAt: 0,
      updatedHLC: 1,
    };

    await mock.saveBoard(board);
    render(<App />);

    await act(async () => {
      await useMoodboardStore.getState().openBoard(board.id);
      useCoordinatorStore.getState().setDestination({ type: 'moodboard', id: board.id });
    });

    await waitFor(() => {
      expect(screen.getByTestId('moodboard-studio-view')).toBeInTheDocument();
    });

    // 1. Add & test paletteStrip (click swatch selects, drag swatch moves, right-click shows swatch menu, Delete removes)
    fireEvent.click(screen.getByRole('button', { name: '添加色卡条' }));
    const paletteNode = useMoodboardStore
      .getState()
      .activeBoard!.nodes.find((n) => 'paletteStrip' in n.kind)!;
    expect(paletteNode).toBeTruthy();

    act(() => {
      useMoodboardStore.getState().setSelectedNodeIds([]);
    });
    const paletteEl = document.querySelector(`[data-board-node-id="${paletteNode.id}"]`)!;
    const firstSwatch = paletteEl.querySelector('[data-swatch-hex]') as HTMLElement;
    expect(firstSwatch).not.toBeNull();

    const prePalFrame = { ...paletteNode.frame };
    fireEvent.mouseDown(firstSwatch, { button: 0, clientX: 300, clientY: 200 });
    expect(useMoodboardStore.getState().selectedNodeIds).toContain(paletteNode.id);
    fireEvent.mouseMove(window, { clientX: 360, clientY: 250 });
    fireEvent.mouseUp(window, { clientX: 360, clientY: 250 });

    const movedPal = useMoodboardStore
      .getState()
      .activeBoard!.nodes.find((n) => n.id === paletteNode.id)!;
    expect(movedPal.frame.x).toBeGreaterThan(prePalFrame.x);
    expect(movedPal.frame.y).toBeGreaterThan(prePalFrame.y);

    // Right-click swatch opens portaled <Popover> context menu with copy, auto-sync & remove
    fireEvent.contextMenu(firstSwatch, { clientX: 360, clientY: 250 });
    const ctxMenu = await screen.findByTestId('moodboard-node-context-menu');
    const popoverDialog = ctxMenu.closest('[role="dialog"]');
    expect(popoverDialog).toHaveClass('charkle-popover-panel');
    expect(popoverDialog).toHaveAttribute('data-no-lens', 'true');
    expect(screen.getByRole('button', { name: /复制色值 #/ })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /自动同步板内色板/ })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /从情绪板移除/ })).toBeInTheDocument();

    // Close menu and press Delete -> removes paletteStrip cleanly
    fireEvent.keyDown(window, { key: 'Escape' });
    fireEvent.keyDown(window, { key: 'Delete' });
    expect(
      useMoodboardStore.getState().activeBoard!.nodes.some((n) => n.id === paletteNode.id),
    ).toBe(false);

    // 2. Add & test note (drag body moves, double-click edits, Escape exits editing, Delete removes)
    fireEvent.click(screen.getByRole('button', { name: '添加便签' }));
    const noteNode = useMoodboardStore
      .getState()
      .activeBoard!.nodes.find((n) => 'note' in n.kind)!;
    expect(noteNode).toBeTruthy();

    act(() => {
      useMoodboardStore.getState().setSelectedNodeIds([]);
    });
    const noteEl = document.querySelector(`[data-board-node-id="${noteNode.id}"]`)!;
    expect(noteEl.querySelector('textarea')).toBeNull(); // non-editing does not block drags

    const preNoteFrame = { ...noteNode.frame };
    fireEvent.mouseDown(noteEl, { button: 0, clientX: 400, clientY: 300 });
    expect(useMoodboardStore.getState().selectedNodeIds).toContain(noteNode.id);
    fireEvent.mouseMove(window, { clientX: 455, clientY: 345 });
    fireEvent.mouseUp(window, { clientX: 455, clientY: 345 });

    const movedNote = useMoodboardStore
      .getState()
      .activeBoard!.nodes.find((n) => n.id === noteNode.id)!;
    expect(movedNote.frame.x).toBeGreaterThan(preNoteFrame.x);
    expect(movedNote.frame.y).toBeGreaterThan(preNoteFrame.y);

    // Double-click enters inline editing, Escape exits while keeping note selected
    fireEvent.doubleClick(noteEl);
    const noteTextarea = noteEl.querySelector('textarea') as HTMLTextAreaElement;
    expect(noteTextarea).not.toBeNull();
    fireEvent.keyDown(noteTextarea, { key: 'Escape' });
    expect(noteEl.querySelector('textarea')).toBeNull();
    expect(useMoodboardStore.getState().selectedNodeIds).toContain(noteNode.id);

    fireEvent.keyDown(window, { key: 'Delete' });
    expect(
      useMoodboardStore.getState().activeBoard!.nodes.some((n) => n.id === noteNode.id),
    ).toBe(false);

    // 3. Add & test groupFrame (drag title header moves, double-click renames, Escape exits, Delete removes)
    fireEvent.click(screen.getByRole('button', { name: '添加分组框' }));
    const groupNode = useMoodboardStore
      .getState()
      .activeBoard!.nodes.find((n) => 'groupFrame' in n.kind)!;
    expect(groupNode).toBeTruthy();

    act(() => {
      useMoodboardStore.getState().setSelectedNodeIds([]);
    });
    const groupEl = document.querySelector(`[data-board-node-id="${groupNode.id}"]`)!;
    expect(groupEl.querySelector('input')).toBeNull(); // title renders as non-blocking span

    const preGroupFrame = { ...groupNode.frame };
    const titleSpan = groupEl.querySelector('span[title="双击重命名分组"]') as HTMLElement;
    expect(titleSpan).not.toBeNull();
    fireEvent.mouseDown(titleSpan, { button: 0, clientX: 350, clientY: 220 });
    expect(useMoodboardStore.getState().selectedNodeIds).toContain(groupNode.id);
    fireEvent.mouseMove(window, { clientX: 410, clientY: 270 });
    fireEvent.mouseUp(window, { clientX: 410, clientY: 270 });

    const movedGroup = useMoodboardStore
      .getState()
      .activeBoard!.nodes.find((n) => n.id === groupNode.id)!;
    expect(movedGroup.frame.x).toBeGreaterThan(preGroupFrame.x);
    expect(movedGroup.frame.y).toBeGreaterThan(preGroupFrame.y);

    // Double-click title enters inline rename input; Escape exits
    fireEvent.doubleClick(titleSpan);
    const groupInput = groupEl.querySelector('input') as HTMLInputElement;
    expect(groupInput).not.toBeNull();
    fireEvent.keyDown(groupInput, { key: 'Escape' });
    expect(groupEl.querySelector('input')).toBeNull();

    fireEvent.keyDown(window, { key: 'Delete' });
    expect(
      useMoodboardStore.getState().activeBoard!.nodes.some((n) => n.id === groupNode.id),
    ).toBe(false);
  });

  // -------------------------------------------------------------------------
  // 13. TopEdgeDropShelf Post-Subscribe Host Visibility Convergence (Tauri Startup Race)
  // -------------------------------------------------------------------------

  it('re-syncs Shelf expanded & pinned visibility after async subscribeEvents resolves in Tauri runtime', async () => {
    const winObj = window as unknown as { __TAURI_INTERNALS__?: unknown };
    const hadTauriInternals = '__TAURI_INTERNALS__' in winObj;
    const prevTauriInternals = winObj.__TAURI_INTERNALS__;
    winObj.__TAURI_INTERNALS__ = {};

    try {
      let resolveSubscribe!: (unlisten: () => void) => void;
      const transportObj: CharkleTransport = mock;
      vi.spyOn(transportObj, 'subscribeEvents').mockImplementation(
        () =>
          new Promise<() => void>((resolve) => {
            resolveSubscribe = resolve;
          }),
      );

      let statusCallCount = 0;
      const baseStatus = await mock.getDesktopIntegrationStatus();
      vi.spyOn(transportObj, 'getDesktopIntegrationStatus').mockImplementation(async () => {
        statusCallCount += 1;
        // Simulate shelf:state opening AFTER initial mount probe but BEFORE subscribeEvents resolved
        return {
          ...baseStatus,
          shelfVisible: statusCallCount >= 2,
          shelfPinned: statusCallCount >= 2,
        };
      });

      render(<TopEdgeDropShelf />);

      await waitFor(() => {
        expect(statusCallCount).toBe(1);
      });
      expect(screen.getByTestId('top-edge-drop-shelf')).toHaveAttribute('data-expanded', 'false');

      // Resolving subscribeEvents triggers post-subscribe host visibility re-sync -> expanded becomes true!
      await act(async () => {
        resolveSubscribe(() => {});
      });

      await waitFor(() => {
        expect(statusCallCount).toBeGreaterThanOrEqual(2);
        expect(screen.getByTestId('top-edge-drop-shelf')).toHaveAttribute('data-expanded', 'true');
      });
    } finally {
      if (hadTauriInternals) {
        winObj.__TAURI_INTERNALS__ = prevTauriInternals;
      } else {
        delete winObj.__TAURI_INTERNALS__;
      }
    }
  });
});
