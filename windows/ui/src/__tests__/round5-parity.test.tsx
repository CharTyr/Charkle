import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { App, extractWebUrlFromPaste } from '../App';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import { GalleryRingView } from '../features/gallery/GalleryRingView';
import { TopFilterCapsule } from '../features/gallery/TopFilterCapsule';
import { effectiveAspectRatio } from '../features/gallery/masonryLayout';
import {
  DEFAULT_RING_GALLERY_PARAMS,
  RingCardTrack,
  RingCubicBezier,
  adaptiveCardScale,
  createDefaultRingParams,
  depthOfFieldBlur,
  farFadeAmount,
  outsideProjectedHalfWidth,
  outsideSilhouetteAngle,
  releaseGlide,
  ringRadius,
  visibleOutsideCards,
} from '../features/gallery/ringGalleryMath';
import {
  resolveMoodboardDockLayout,
  resolveMoodboardDockTier,
} from '../features/moodboard/MoodboardStudioView';
import { SettingsOverlay } from '../features/settings/SettingsOverlay';
import { SidebarView } from '../features/sidebar/SidebarView';
import {
  DEFAULT_INSPECTOR_CARD_ORDER,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  useSyncAIStore,
} from '../stores';
import {
  createDefaultFilterCriteria,
  type AssetRecord,
  type MoodboardDocument,
} from '../types/domain';

function resetStores() {
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
    id: '91000000-0000-4000-8000-000000000001',
    contentHash: 'hash-r5',
    mediaKind: 'image',
    mimeType: 'image/png',
    title: 'Ring Sample',
    fileName: 'ring-sample.png',
    notes: '',
    tags: [],
    suggestedTags: [],
    rating: 0,
    pixelWidth: 1200,
    pixelHeight: 800,
    fileSizeBytes: 128_000,
    dominantColors: [{ hex: '#D4A373', l: 70, a: 12, b: 30, proportion: 0.7 }],
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

describe('Round 5 Full macOS Parity Regressions (3D Ring Gallery, Responsive Dock, WebBookmark Aspect, Minimal Mode, Paste URL)', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    localStorage.clear();
    mock = new InMemoryMockTransport(true);
    setTransport(mock);
    resetStores();
  });

  // -------------------------------------------------------------------------
  // 1. ringGalleryMath.ts — Exact 1:1 macOS Geometry, O(log N) Track, Silhouette & Glide
  // -------------------------------------------------------------------------

  it('computes variable-width RingCardTrack, O(log N) nearest lookup, silhouette split, painter sort, and Reduced Motion glide', () => {
    const params = createDefaultRingParams();
    expect(params.slotCount).toBe(22);
    expect(params.cardWidth).toBe(180);
    expect(params.cardHeight).toBe(300);
    expect(params.cardGap).toBe(18);
    expect(params.perspective).toBe(1500);
    expect(params.depthBlur).toBe(2);
    expect(params.farFade).toBe(0.96);
    expect(params.cornerRadius).toBe(32);
    expect(params.nearPlane).toBe(140);

    const R = ringRadius(params);
    expect(R).toBeCloseTo((22 * 198) / (2 * Math.PI), 4);

    // Closed-form projected silhouette half-width: R * P / sqrt(P^2 + 2*P*R)
    const expectedHalfW = (R * 1500) / Math.sqrt(1500 * 1500 + 2 * 1500 * R);
    expect(outsideProjectedHalfWidth(R, 1500)).toBeCloseTo(expectedHalfW, 5);

    // Viewport-adaptive cardScale stays cleanly bounded across desktop & compact sizes
    const wideScale = adaptiveCardScale(1440, 900, 68, 72, params);
    const narrowScale = adaptiveCardScale(640, 480, 68, 72, params);
    expect(wideScale).toBeGreaterThan(narrowScale);
    expect(narrowScale).toBeGreaterThanOrEqual(0.34);
    expect(wideScale).toBeLessThanOrEqual(2.8);

    // Variable-width RingCardTrack (portrait vs square vs landscape — zero landscape cropping)
    const assets: AssetRecord[] = [
      makeAsset({ id: 'r-0', pixelWidth: 600, pixelHeight: 1000 }), // portrait 0.6 -> 180px
      makeAsset({ id: 'r-1', pixelWidth: 1600, pixelHeight: 900 }), // landscape 1.778 -> 533px
      makeAsset({ id: 'r-2', pixelWidth: 1000, pixelHeight: 1000 }), // square 1.0 -> 300px
      makeAsset({ id: 'r-3', pixelWidth: 1200, pixelHeight: 750 }), // 1.6 -> 480px
      makeAsset({ id: 'r-4', pixelWidth: 900, pixelHeight: 1200 }), // 0.75 -> 225px
      makeAsset({ id: 'r-5', pixelWidth: 1920, pixelHeight: 1080 }), // 1.778 -> 533px
    ];
    const track = RingCardTrack.build(assets, params);
    expect(track.count).toBe(6);
    expect(track.cardWidths[1]).toBeGreaterThan(track.cardWidths[0] * 2);

    // O(log N) nearestVirtualIndex matches centerArc across positive & negative laps
    for (const vIdx of [-7, -1, 0, 2, 5, 11]) {
      const arc = track.centerArcForVirtualIndex(vIdx);
      expect(track.nearestVirtualIndex(arc)).toBe(vIdx);
      expect(track.nearestVirtualIndex(arc + 5)).toBe(vIdx);
    }

    // Interpolated front card width transitions smoothly between portrait and landscape
    const midArc = 0.5 * (track.centerArcForVirtualIndex(0) + track.centerArcForVirtualIndex(1));
    const midW = track.interpolatedFrontCardWidth(midArc);
    expect(midW).toBeGreaterThan(track.cardWidths[0]);
    expect(midW).toBeLessThan(track.cardWidths[1]);

    // Silhouette angle & visibleOutsideCards painter's order (farthest Z first)
    const thetaSil = outsideSilhouetteAngle(R, params.perspective);
    expect(thetaSil).toBeGreaterThan(1.0);
    expect(thetaSil).toBeLessThan(Math.PI / 2);

    const visible = visibleOutsideCards({
      track,
      offset: 0,
      params,
      viewportWidth: 1280,
      viewportHeight: 760,
      cardScale: adaptiveCardScale(1280, 760, 68, 72, params),
    });
    expect(visible.length).toBeGreaterThanOrEqual(4);
    for (let i = 1; i < visible.length; i++) {
      // Painter's order: non-decreasing centerZ (farthest negative Z drawn first, nearest Z=0 last)
      expect(visible[i].centerZ).toBeGreaterThanOrEqual(visible[i - 1].centerZ - 0.02);
    }
    // Every projected card has valid non-zero monotonic slice width & seamAlpha in (0, 1]
    for (const card of visible) {
      expect(card.uMax - card.uMin).toBeGreaterThan(0.25);
      expect(card.seamAlpha).toBeGreaterThan(0);
      expect(card.seamAlpha).toBeLessThanOrEqual(1);
    }

    // Bezier curve & DoF / FarFade & Release Glide (normal vs Reduced Motion <= 0.20s cap)
    expect(RingCubicBezier.dragGlide.evaluate(0)).toBe(0);
    expect(RingCubicBezier.dragGlide.evaluate(1)).toBe(1);
    expect(RingCubicBezier.dragGlide.evaluate(0.5)).toBeGreaterThan(0.5);

    expect(depthOfFieldBlur(0, 640, 0, R, 3)).toBe(0);
    expect(depthOfFieldBlur(600, 640, 0, R, 3)).toBeGreaterThan(2);
    expect(farFadeAmount(0, R, 0.97)).toBe(0);
    expect(farFadeAmount(-2 * R, R, 0.97)).toBeCloseTo(0.97, 4);

    const normalGlide = releaseGlide(10, -1400, track, false);
    expect(normalGlide.duration).toBeGreaterThanOrEqual(0.42);
    expect(normalGlide.duration).toBeLessThanOrEqual(1.1);

    const reducedGlide = releaseGlide(45, -2400, track, true);
    expect(reducedGlide.duration).toBeLessThanOrEqual(0.2);
  });

  // -------------------------------------------------------------------------
  // 2. GalleryRingView + 4th TopFilterCapsule Mode + Tuning Panel + Overlay Guard
  // -------------------------------------------------------------------------

  it('switches to 4th ringGallery mode, collapses tuning panel by default, closes on Escape, suspends arrows behind overlays, and opens plain webBookmark in browser', async () => {
    const openUrlSpy = vi.spyOn(mock, 'openExternalUrl').mockResolvedValue();
    const markOpenedSpy = vi.spyOn(mock, 'markAssetOpened').mockResolvedValue(null);

    const webAsset = makeAsset({
      id: '91000000-0000-4000-8000-000000000010',
      mediaKind: 'webBookmark',
      mimeType: 'text/uri-list',
      title: 'Tauri Docs',
      fileName: 'tauri.url',
      sourceURL: 'https://tauri.app/start/',
      sourceDomain: 'tauri.app',
      pixelWidth: 1200,
      pixelHeight: 750,
    });
    const imgAsset = makeAsset({
      id: '91000000-0000-4000-8000-000000000011',
      title: 'Studio Poster',
      pixelWidth: 1000,
      pixelHeight: 1400,
    });

    // TopFilterCapsule exposes 4th layout button "环形画廊" and hides density slider when active
    const { unmount: unmountTop } = render(<TopFilterCapsule galleryViewportWidth={1100} />);
    const ringBtn = screen.getByRole('radio', { name: '环形画廊' });
    expect(ringBtn).toBeInTheDocument();
    expect(screen.getByRole('slider', { name: '卡片缩放尺寸' })).toBeInTheDocument();

    fireEvent.click(ringBtn);
    expect(useCoordinatorStore.getState().layoutMode).toBe('ringGallery');
    expect(screen.queryByRole('slider', { name: '卡片缩放尺寸' })).not.toBeInTheDocument();
    unmountTop();

    // Render GalleryRingView with plain webBookmark + image
    render(<GalleryRingView assets={[webAsset, imgAsset]} topInset={68} />);
    const ringRoot = screen.getByTestId('gallery-ring-view');
    expect(ringRoot).toBeInTheDocument();
    // Outer full-viewport Ring container MUST NOT carry data-asset-hex (keeps top/bottom glass pills Light over #F6F6F5)
    expect(ringRoot).not.toHaveAttribute('data-asset-hex');
    expect(ringRoot).not.toHaveAttribute('data-asset-colors');
    expect(screen.getByTestId('ring-gallery-nav-pill')).toBeInTheDocument();

    // Tuning panel is strictly collapsed by default
    expect(screen.queryByTestId('ring-tuning-panel')).not.toBeInTheDocument();

    // Opening tuning panel shows all 4 bespoke CharkleSlider controls + Reset
    fireEvent.click(screen.getByTestId('ring-tuning-toggle'));
    expect(screen.getByTestId('ring-tuning-panel')).toBeInTheDocument();
    const perspSlider = screen.getByTestId('ring-slider-perspective');
    expect(screen.getByTestId('ring-slider-depth-blur')).toBeInTheDocument();
    expect(screen.getByTestId('ring-slider-far-fade')).toBeInTheDocument();
    expect(screen.getByTestId('ring-slider-corner-radius')).toBeInTheDocument();

    // Adjust perspective slider, verify reset button enables & restores default 1500px
    fireEvent.keyDown(perspSlider, { key: 'ArrowRight' });
    expect(perspSlider).toHaveAttribute('aria-valuenow', String(DEFAULT_RING_GALLERY_PARAMS.perspective + 10));
    fireEvent.click(screen.getByRole('button', { name: '重置默认' }));
    expect(perspSlider).toHaveAttribute('aria-valuenow', String(DEFAULT_RING_GALLERY_PARAMS.perspective));

    // Escape closes the tuning panel cleanly
    fireEvent.keyDown(window, { key: 'Escape' });
    expect(screen.queryByTestId('ring-tuning-panel')).not.toBeInTheDocument();

    // While an overlay (Settings) is open, ArrowRight is suspended (does not step front card)
    act(() => {
      useCoordinatorStore.setState({ settingsOpen: true, selectedAssetIds: [webAsset.id] });
    });
    fireEvent.keyDown(window, { key: 'ArrowRight' });
    expect(useCoordinatorStore.getState().selectedAssetIds).toEqual([webAsset.id]);

    // Closing overlay & clicking "浏览器打开" opens plain webBookmark directly in default browser
    act(() => {
      useCoordinatorStore.setState({ settingsOpen: false });
    });
    fireEvent.click(screen.getByRole('button', { name: /浏览器打开/ }));
    await waitFor(() => {
      expect(openUrlSpy).toHaveBeenCalledWith('https://tauri.app/start/');
      expect(markOpenedSpy).toHaveBeenCalledWith(webAsset.id);
    });
    expect(useCoordinatorStore.getState().quickLookAssetId).toBeNull();
  });

  // -------------------------------------------------------------------------
  // 3. Responsive Moodboard Dock Tiers (1200 / 720 / 520 / 400) & Anti-Clipping Classes
  // -------------------------------------------------------------------------

  it('resolves Moodboard dock layout tiers across 1200/720/520/400px and enforces anti-clipping stage bounds', async () => {
    expect(resolveMoodboardDockTier(1200)).toBe('wide');
    expect(resolveMoodboardDockTier(720)).toBe('medium');
    expect(resolveMoodboardDockTier(520)).toBe('compact');
    expect(resolveMoodboardDockTier(400)).toBe('compact');

    const w1200 = resolveMoodboardDockLayout(1200);
    expect(w1200.inlineToolOptions).toBe(true);
    expect(w1200.compactButtons).toBe(false);
    expect(w1200.scrollDockFallback).toBe(false);

    const w720 = resolveMoodboardDockLayout(720);
    expect(w720.tier).toBe('medium');
    expect(w720.inlineToolOptions).toBe(false);
    expect(w720.showInsertLabels).toBe(true);

    const w520 = resolveMoodboardDockLayout(520);
    expect(w520.tier).toBe('compact');
    expect(w520.compactButtons).toBe(true);
    expect(w520.showInsertLabels).toBe(false);
    expect(w520.scrollDockFallback).toBe(false);

    const w400 = resolveMoodboardDockLayout(400);
    expect(w400.tier).toBe('compact');
    expect(w400.scrollDockFallback).toBe(true);
    expect(w400.compactHeader).toBe(true);

    const board: MoodboardDocument = {
      id: '82000000-0000-4000-8000-000000000001',
      title: '响应式测试板',
      subtitle: '',
      mode: { freeform: {} },
      nodes: [],
      connectors: [],
      inkStrokes: [],
      extractedPalette: [],
      candidateAssetIDs: [],
      pinnedOffline: false,
      viewportCenter: { x: 0, y: 0 },
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

    const studio = await screen.findByTestId('moodboard-studio-view');
    const stage = screen.getByTestId('moodboard-canvas-stage');
    expect(studio.className).toContain('min-h-0');
    expect(studio.className).toContain('min-w-0');
    expect(stage.className).toContain('min-h-0');
    expect(stage.className).toContain('min-w-0');
    expect(stage.className).toContain('overflow-hidden');
    expect(screen.getByTestId('moodboard-bottom-hud')).toBeInTheDocument();
  });

  // -------------------------------------------------------------------------
  // 4. masonryLayout.ts Real Aspect Ratio on webBookmark (Never Hardcoded 1.25)
  // -------------------------------------------------------------------------

  it('uses real pixel aspect ratio on webBookmark cards in masonryLayout instead of hardcoded 1.25', () => {
    const editorialWebCard = makeAsset({
      mediaKind: 'webBookmark',
      pixelWidth: 1200,
      pixelHeight: 750, // exact 1.60
    });
    expect(effectiveAspectRatio(editorialWebCard, 0.5, 2.4)).toBeCloseTo(1.6, 3);

    const tallWebCard = makeAsset({
      mediaKind: 'webBookmark',
      pixelWidth: 800,
      pixelHeight: 1000, // exact 0.80
    });
    expect(effectiveAspectRatio(tallWebCard, 0.5, 2.4)).toBeCloseTo(0.8, 3);

    // Fallback ratios when pixel dimensions are absent
    const missingPixelsGeneric = makeAsset({
      mediaKind: 'webBookmark',
      pixelWidth: 0,
      pixelHeight: 0,
    });
    expect(effectiveAspectRatio(missingPixelsGeneric, 0.5, 2.4)).toBeCloseTo(1.6, 3);

    const missingPixelsGithub = makeAsset({
      mediaKind: 'webBookmark',
      pixelWidth: 0,
      pixelHeight: 0,
      richMetadata: {
        githubRepo: {
          owner: 'tauri-apps',
          repo: 'tauri',
          fullName: 'tauri-apps/tauri',
          stars: 1,
          forks: 1,
          topics: [],
        },
      },
    });
    expect(effectiveAspectRatio(missingPixelsGithub, 0.5, 2.4)).toBeCloseTo(1.32, 3);
  });

  // -------------------------------------------------------------------------
  // 5. 64px Collapsed Sidebar + Settings 4th Layout + Minimal Shelf Mode + Paste URL
  // -------------------------------------------------------------------------

  it('renders 64px collapsed Sidebar, 4th Ring Gallery option & Minimal Shelf Mode in Settings, and parses share copy URLs cleanly', async () => {
    // 1. Collapsed Sidebar renders compact rail filling parent 76px slot
    useCoordinatorStore.setState({ sidebarCollapsed: true });
    const { container: sidebarContainer, unmount: unmountSidebar } = render(<SidebarView />);
    const aside = sidebarContainer.querySelector('aside');
    expect(aside).not.toBeNull();
    expect(aside).toHaveAttribute('data-collapsed', 'true');
    expect(aside!.className).toContain('w-full');
    unmountSidebar();

    // 2. Settings -> General shows 4th option "环形画廊"
    useCoordinatorStore.setState({
      sidebarCollapsed: false,
      settingsOpen: true,
      settingsTab: 'general',
    });
    const setMinimalSpy = vi.spyOn(mock, 'setMinimalMode');
    render(<SettingsOverlay />);
    const ringOpt = await screen.findByRole('radio', { name: '环形画廊' });
    fireEvent.click(ringOpt);
    expect(useCoordinatorStore.getState().layoutMode).toBe('ringGallery');

    // 3. Settings -> Top-Edge Drop Shelf shows Minimal Background Mode section & invokes setMinimalMode(true)
    act(() => {
      useCoordinatorStore.setState({ settingsTab: 'dropShelf' });
    });
    expect(await screen.findByTestId('settings-minimal-mode-section')).toBeInTheDocument();
    const enterMinimalBtn = screen.getByTestId('settings-enter-minimal-mode-btn');
    fireEvent.click(enterMinimalBtn);
    await waitFor(() => {
      expect(setMinimalSpy).toHaveBeenCalledWith(true);
    });

    const minimalToggle = screen.getByRole('switch', { name: '启用极简低占用后台模式' });
    expect(minimalToggle).toBeInTheDocument();

    // 4. App.tsx paste URL extraction parity (balanced parens, www., short share text vs long prose & bare filenames)
    expect(
      extractWebUrlFromPaste('(https://en.wikipedia.org/wiki/Swift_(programming_language))。'),
    ).toBe('https://en.wikipedia.org/wiki/Swift_(programming_language)');
    expect(extractWebUrlFromPaste('www.tauri.app/start/')).toBe('https://www.tauri.app/start/');
    expect(extractWebUrlFromPaste('推荐设计站 https://example.com/gallery 看看！')).toBe(
      'https://example.com/gallery',
    );
    expect(extractWebUrlFromPaste('README.md')).toBeNull();
    expect(extractWebUrlFromPaste(`${'这是一段很长的笔记正文，不应该当成链接解析。'.repeat(20)} https://example.com`)).toBeNull();
  });
});
