import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from '../App';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import {
  applyAccentToDocument,
  contrastRatio,
  deriveFluentAccentPalette,
  relativeLuminance,
} from '../design-system';
import {
  DEFAULT_INSPECTOR_CARD_ORDER,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  useSyncAIStore,
} from '../stores';
import { createDefaultFilterCriteria } from '../types/domain';

interface NodeFsLike {
  existsSync: (p: string) => boolean;
  readFileSync: (p: string, encoding: 'utf8') => string;
  readdirSync: (p: string, opts: { withFileTypes: true }) => Array<{
    name: string;
    isDirectory: () => boolean;
    isFile: () => boolean;
  }>;
}

interface NodePathLike {
  resolve: (...segments: string[]) => string;
  join: (...segments: string[]) => string;
}

async function loadNodeFsAndPath(): Promise<{ fs: NodeFsLike; path: NodePathLike; cwd: string }> {
  const fsSpec = 'node:fs';
  const pathSpec = 'node:path';
  const fs = (await import(/* @vite-ignore */ fsSpec)) as NodeFsLike;
  const path = (await import(/* @vite-ignore */ pathSpec)) as NodePathLike;
  const cwd = (globalThis as { process?: { cwd: () => string } }).process?.cwd() ?? '.';
  return { fs, path, cwd };
}

function collectSourceFiles(
  fs: NodeFsLike,
  path: NodePathLike,
  rootDir: string,
  acc: string[] = [],
): string[] {
  for (const entry of fs.readdirSync(rootDir, { withFileTypes: true })) {
    const full = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      collectSourceFiles(fs, path, full, acc);
    } else if (entry.isFile() && /\.(ts|tsx|css)$/.test(entry.name)) {
      acc.push(full);
    }
  }
  return acc;
}

function parseHexToRgb(hex: string): [number, number, number] {
  const cleaned = hex.replace('#', '');
  return [
    Number.parseInt(cleaned.slice(0, 2), 16),
    Number.parseInt(cleaned.slice(2, 4), 16),
    Number.parseInt(cleaned.slice(4, 6), 16),
  ];
}

function rgbToHsl(r: number, g: number, b: number): [number, number, number] {
  const rn = r / 255;
  const gn = g / 255;
  const bn = b / 255;
  const max = Math.max(rn, gn, bn);
  const min = Math.min(rn, gn, bn);
  const d = max - min;
  const l = (max + min) / 2;
  let h = 0;
  let s = 0;
  if (d !== 0) {
    s = d / (1 - Math.abs(2 * l - 1));
    if (max === rn) h = ((gn - bn) / d) % 6;
    else if (max === gn) h = (bn - rn) / d + 2;
    else h = (rn - gn) / d + 4;
    h *= 60;
    if (h < 0) h += 360;
  }
  return [h, s, l];
}

function resetAllStores() {
  useCoordinatorStore.setState({
    themeMode: 'light',
    accentSource: 'studio',
    surfaceState: null,
    sidebarOpen: true,
    sidebarCollapsed: false,
    sidebarSearchFocusNonce: 0,
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

describe('Fluent 2 Desktop Redesign Architecture & Regressions', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    localStorage.clear();
    document.documentElement.removeAttribute('data-backdrop');
    document.documentElement.removeAttribute('data-accent-source');
    document.documentElement.removeAttribute('data-theme');
    document.documentElement.classList.remove('dark');
    for (const prop of [
      '--accent',
      '--accent-hover',
      '--accent-pressed',
      '--accent-soft',
      '--accent-ring',
      '--accent-text',
    ]) {
      document.documentElement.style.removeProperty(prop);
    }
    mock = new InMemoryMockTransport(true);
    setTransport(mock);
    resetAllStores();
  });

  // -------------------------------------------------------------------------
  // 1. Single-Entry Uniqueness across <App /> Shell (§3.3)
  // -------------------------------------------------------------------------

  it('enforces single-entry uniqueness for main search (Sidebar), Inspector toggle (Titlebar), and Settings/Sync (Sidebar footer)', async () => {
    render(<App />);

    await waitFor(() => {
      expect(screen.getByTestId('gallery-stage')).toBeInTheDocument();
    });

    const sidebar = screen.getByRole('complementary', { name: '主导航侧边栏' });
    const titlebar = document.querySelector<HTMLElement>('header.charkle-mica-titlebar')!;
    const galleryStage = screen.getByTestId('gallery-stage');
    expect(titlebar).not.toBeNull();

    // Exactly 1 main search input (`aria-label="搜索素材"`), housed inside Sidebar only
    const searchInputs = screen.getAllByRole('textbox', { name: '搜索素材' });
    expect(searchInputs).toHaveLength(1);
    expect(sidebar.contains(searchInputs[0])).toBe(true);
    expect(titlebar.contains(searchInputs[0])).toBe(false);
    expect(galleryStage.contains(searchInputs[0])).toBe(false);

    // Exactly 1 Inspector toggle button, housed inside the slim right-column Titlebar only
    const inspectorToggles = screen.getAllByRole('button', { name: /^(隐藏|显示)检查器$/ });
    expect(inspectorToggles).toHaveLength(1);
    expect(titlebar.contains(inspectorToggles[0])).toBe(true);
    expect(galleryStage.contains(inspectorToggles[0])).toBe(false);

    // Exactly 1 Settings entry (`aria-label="打开设置中心"`), housed inside Sidebar footer only
    const settingsBtns = screen.getAllByRole('button', { name: '打开设置中心' });
    expect(settingsBtns).toHaveLength(1);
    expect(sidebar.contains(settingsBtns[0])).toBe(true);
    expect(titlebar.contains(settingsBtns[0])).toBe(false);

    // Sync status row also lives in Sidebar footer (never duplicated in Titlebar)
    const syncBtns = screen.getAllByRole('button', { name: '同步状态' });
    expect(syncBtns).toHaveLength(1);
    expect(sidebar.contains(syncBtns[0])).toBe(true);
    expect(titlebar.contains(syncBtns[0])).toBe(false);
  });

  // -------------------------------------------------------------------------
  // 2. Ctrl+F (Sidebar Search + Auto-Expand from 64px Rail) vs Ctrl+J (0ms Jump)
  // -------------------------------------------------------------------------

  it('focuses Sidebar search on Ctrl+F (expanding from 64px rail) while Ctrl+J opens JumpAnywhereModal instantaneously', async () => {
    useCoordinatorStore.setState({ sidebarCollapsed: true });
    render(<App />);

    await waitFor(() => {
      expect(screen.getByTestId('gallery-stage')).toBeInTheDocument();
    });

    // Starts collapsed as 76px icon rail with compact search icon button
    const collapsedAside = screen.getByRole('complementary', { name: '主导航侧边栏' });
    expect(collapsedAside).toHaveAttribute('data-collapsed', 'true');
    expect(screen.getByTestId('sidebar-slot').style.width).toBe('76px');
    expect(screen.queryByRole('textbox', { name: '搜索素材' })).toBeNull();

    // Ctrl+F automatically expands the Sidebar and focuses the single search input
    fireEvent.keyDown(window, { key: 'f', ctrlKey: true });

    await waitFor(() => {
      expect(useCoordinatorStore.getState().sidebarCollapsed).toBe(false);
      const searchInput = screen.getByRole('textbox', { name: '搜索素材' });
      expect(document.activeElement).toBe(searchInput);
    });
    const expandedAside = screen.getByRole('complementary', { name: '主导航侧边栏' });
    expect(expandedAside).toHaveAttribute('data-collapsed', 'false');
    expect(screen.getByTestId('sidebar-slot').style.width).toBe('232px');

    // Blur search input and verify Ctrl+J opens JumpAnywhereModal instantaneously
    (document.activeElement as HTMLElement | null)?.blur?.();
    fireEvent.keyDown(window, { key: 'j', ctrlKey: true });

    expect(useCoordinatorStore.getState().jumpOpen).toBe(true);
    const jumpModal = screen.getByTestId('jump-anywhere-modal');
    expect(jumpModal).toBeInTheDocument();
    expect(jumpModal.className).toContain('win-acrylic');

    // Ctrl+F while Jump modal is open must NOT steal focus or fire sidebar search focus
    const prevNonce = useCoordinatorStore.getState().sidebarSearchFocusNonce;
    fireEvent.keyDown(window, { key: 'f', ctrlKey: true });
    expect(useCoordinatorStore.getState().sidebarSearchFocusNonce).toBe(prevNonce);

    // Escape closes JumpAnywhereModal cleanly
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => {
      expect(screen.queryByTestId('jump-anywhere-modal')).not.toBeInTheDocument();
    });
  });

  // -------------------------------------------------------------------------
  // 3. Accent Strategy: Studio Cobalt Default, Windows Accent Toggle, WCAG >= 4.5:1 & Live Surface Updates
  // -------------------------------------------------------------------------

  it('defaults to Studio Cobalt, toggles Windows System Accent with WCAG >= 4.5:1 calibration across extremes, and reacts to live emitSurfaceState', async () => {
    // Default Studio Cobalt palettes
    expect(deriveFluentAccentPalette(null, false).accent).toBe('#2A60E0');
    expect(deriveFluentAccentPalette(null, true).accent).toBe('#5B8DEF');

    // Extreme light (#FFF200) and extreme dark (#0A0B0E) system colors calibrate to WCAG >= 4.5:1
    const lightGalleryLum = relativeLuminance(0xf6, 0xf6, 0xf5);
    const darkSurfaceLum = relativeLuminance(0x24, 0x26, 0x2c);

    for (const extremeHex of ['#FFF200', '#0A0B0E']) {
      for (const isDark of [false, true]) {
        const palette = deriveFluentAccentPalette(extremeHex, isDark);
        expect(palette.accent).toMatch(/^#[0-9A-F]{6}$/);
        const [ar, ag, ab] = parseHexToRgb(palette.accent);
        const [tr, tg, tb] = parseHexToRgb(palette.text);
        const accentLum = relativeLuminance(ar, ag, ab);
        const textLum = relativeLuminance(tr, tg, tb);
        const surfaceLum = isDark ? darkSurfaceLum : lightGalleryLum;

        expect(contrastRatio(accentLum, surfaceLum)).toBeGreaterThanOrEqual(4.5);
        expect(contrastRatio(accentLum, textLum)).toBeGreaterThanOrEqual(4.5);
      }
    }

    // Mount full <App />, open Settings -> General, and test toggle + live emitSurfaceState
    mock.mockSystemAccentHex = '#0078D4';
    render(<App />);

    await waitFor(() => {
      expect(useCoordinatorStore.getState().surfaceState?.systemAccentHex).toBe('#0078D4');
    });

    // Studio Cobalt stays active while accentSource === 'studio'
    expect(useCoordinatorStore.getState().accentSource).toBe('studio');
    expect(document.documentElement.style.getPropertyValue('--accent')).toBe('#2A60E0');

    // Open Settings via single Sidebar button and toggle "跟随 Windows 系统强调色"
    fireEvent.click(screen.getByRole('button', { name: '打开设置中心' }));
    const accentSection = await screen.findByTestId('settings-accent-controls');
    expect(within(accentSection).getByTestId('settings-accent-swatch').textContent).toContain(
      '#2A60E0',
    );

    const followSwitch = within(accentSection).getByRole('switch', {
      name: '跟随 Windows 系统强调色',
    });
    expect(followSwitch).toHaveAttribute('aria-checked', 'false');

    fireEvent.click(followSwitch);
    expect(useCoordinatorStore.getState().accentSource).toBe('windows');
    expect(localStorage.getItem('charkle.win.accentSource')).toBe('windows');
    expect(within(accentSection).getByTestId('settings-accent-swatch').textContent).toContain(
      '#0078D4',
    );
    const expectedBlue = deriveFluentAccentPalette('#0078D4', false).accent;
    expect(document.documentElement.style.getPropertyValue('--accent')).toBe(expectedBlue);

    // Live Windows DWM accent change via emitSurfaceState updates swatch & :root tokens immediately
    act(() => {
      mock.emitSurfaceState({
        buildNumber: 26200,
        backdrop: 'mica',
        isDark: false,
        transparencyEnabled: true,
        animationsEnabled: true,
        snapLayoutsSupported: true,
        systemAccentHex: '#FFF200',
      });
    });

    await waitFor(() => {
      expect(useCoordinatorStore.getState().surfaceState?.systemAccentHex).toBe('#FFF200');
      expect(within(accentSection).getByTestId('settings-accent-swatch').textContent).toContain(
        '#FFF200',
      );
    });
    const expectedYellowLight = deriveFluentAccentPalette('#FFF200', false).accent;
    expect(document.documentElement.style.getPropertyValue('--accent')).toBe(expectedYellowLight);

    // Dark theme switch re-calibrates live system accent for Dark surfaces
    await act(async () => {
      await useCoordinatorStore.getState().setThemeMode('dark');
    });
    const expectedYellowDark = deriveFluentAccentPalette('#FFF200', true).accent;
    expect(document.documentElement.style.getPropertyValue('--accent')).toBe(expectedYellowDark);

    // applyAccentToDocument studio fallback restores Studio Dark Cobalt cleanly
    const studioRestored = applyAccentToDocument('studio', '#FFF200', true);
    expect(studioRestored.accent).toBe('#5B8DEF');
  });

  // -------------------------------------------------------------------------
  // 4. Quick Look FLIP Origin Rect Capture from [data-asset-card-id]
  // -------------------------------------------------------------------------

  it('captures quickLookOriginRect from [data-asset-card-id] when opening Quick Look via double-click and Spacebar', async () => {
    render(<App />);

    const targetAssetId = '20000000-0000-4000-8000-000000000001';
    let cardEl: HTMLElement | null = null;
    await waitFor(() => {
      cardEl = document.querySelector<HTMLElement>(`[data-asset-card-id="${targetAssetId}"]`);
      expect(cardEl).not.toBeNull();
    });

    vi.spyOn(cardEl!, 'getBoundingClientRect').mockReturnValue({
      left: 120,
      top: 180,
      width: 240,
      height: 320,
      right: 360,
      bottom: 500,
      x: 120,
      y: 180,
      toJSON: () => ({}),
    });

    // 1. Double-clicking the asset card opens Quick Look with exact FLIP origin rect
    fireEvent.doubleClick(cardEl!);
    expect(useCoordinatorStore.getState().quickLookAssetId).toBe(targetAssetId);
    expect(useCoordinatorStore.getState().quickLookOriginRect).toEqual({
      left: 120,
      top: 180,
      width: 240,
      height: 320,
    });

    // 2. Closing Quick Look and pressing Spacebar on selected asset re-captures exact FLIP origin rect
    act(() => {
      useCoordinatorStore.getState().closeQuickLook();
      useCoordinatorStore.getState().setSelection([targetAssetId], targetAssetId);
    });
    expect(useCoordinatorStore.getState().quickLookAssetId).toBeNull();

    fireEvent.keyDown(window, { key: ' ', code: 'Space' });
    expect(useCoordinatorStore.getState().quickLookAssetId).toBe(targetAssetId);
    expect(useCoordinatorStore.getState().quickLookOriginRect).toEqual({
      left: 120,
      top: 180,
      width: 240,
      height: 320,
    });
  });

  // -------------------------------------------------------------------------
  // 5. Static CSS & Architecture Guardrails (tokens.css + src/ tree)
  // -------------------------------------------------------------------------

  it('enforces static Fluent 2 CSS and architecture guardrails across tokens.css and src/', async () => {
    const { fs, path, cwd } = await loadNodeFsAndPath();
    const tokensPath = path.resolve(cwd, 'src/design-system/tokens.css');
    const tokensCss = fs.readFileSync(tokensPath, 'utf8');
    const strippedCss = tokensCss.replace(/\/\*[\s\S]*?\*\//g, '');

    // 1. Zero `transition: all` or `transition-property: all`
    expect(strippedCss).not.toMatch(/transition(?:-property)?\s*:\s*[^;]*\ball\b/i);

    // 2. Zero per-frame `width` transitions on drawer slots/content
    const drawerSlotBlock = strippedCss.match(/\.charkle-drawer-slot\s*\{[^}]*\}/);
    expect(drawerSlotBlock).not.toBeNull();
    expect(drawerSlotBlock![0]).not.toMatch(/transition/i);
    expect(drawerSlotBlock![0]).not.toMatch(/\bwidth\b/i);

    const drawerContentBlock = strippedCss.match(/\.win-drawer-content\s*\{[^}]*\}/);
    expect(drawerContentBlock).not.toBeNull();
    expect(drawerContentBlock![0]).not.toMatch(/\bwidth\b/i);

    // 3. Explicit `backdrop-filter: none` under BOTH prefers-reduced-transparency AND solidFallback
    const rtmMatch = strippedCss.match(
      /@media\s*\(prefers-reduced-transparency:\s*reduce\)\s*\{[\s\S]*?\n\}/,
    );
    expect(rtmMatch).not.toBeNull();
    for (const cls of ['.win-acrylic', '.win-acrylic-header', '.win-acrylic-dark']) {
      expect(rtmMatch![0]).toContain(cls);
    }
    expect((rtmMatch![0].match(/backdrop-filter:\s*none/g) ?? []).length).toBeGreaterThanOrEqual(3);

    for (const cls of ['.win-acrylic', '.win-acrylic-header', '.win-acrylic-dark']) {
      const escaped = cls.replace('.', '\\.');
      const fallbackRegex = new RegExp(
        `:root\\[data-backdrop="solidFallback"\\]\\s+${escaped}\\s*\\{[^}]*backdrop-filter:\\s*none`,
      );
      expect(strippedCss, `solidFallback rule for ${cls} must disable backdrop-filter`).toMatch(
        fallbackRegex,
      );
    }

    // 4. Zero violet / purple chrome hexes in tokens.css (hue 260°-325° with saturation >= 20%)
    const hexMatches = strippedCss.match(/#[0-9a-fA-F]{6}\b/g) ?? [];
    expect(hexMatches.length).toBeGreaterThan(10);
    for (const hex of hexMatches) {
      const [r, g, b] = parseHexToRgb(hex);
      const [h, s] = rgbToHsl(r, g, b);
      const isViolet = s >= 0.2 && h >= 260 && h <= 325;
      expect(isViolet, `Forbidden violet chrome hex ${hex} (hsl ${h.toFixed(1)}°, ${(s * 100).toFixed(0)}%)`).toBe(
        false,
      );
    }

    // 5. Zero retired lens file or imports anywhere in `src/` (and zero mentions in production code)
    const retiredModuleName = `${'liquid'}${'GlassLens'}`;
    const retiredImportPattern = new RegExp(`(?:import|from|require)[\\s\\S]{0,80}${retiredModuleName}`);
    expect(fs.existsSync(path.resolve(cwd, 'src/design-system', `${retiredModuleName}.ts`))).toBe(
      false,
    );
    const allSrcFiles = collectSourceFiles(fs, path, path.resolve(cwd, 'src'));
    expect(allSrcFiles.length).toBeGreaterThan(20);
    for (const filePath of allSrcFiles) {
      const content = fs.readFileSync(filePath, 'utf8');
      expect(content, `Unexpected retired lens import in ${filePath}`).not.toMatch(
        retiredImportPattern,
      );
      if (!filePath.includes('__tests__')) {
        expect(content, `Unexpected retired lens reference in ${filePath}`).not.toContain(
          retiredModuleName,
        );
        if (filePath.endsWith('.tsx')) {
          expect(content, `Forbidden native <select> in ${filePath}; use CustomSelect`).not.toMatch(
            /<select\b/,
          );
          expect(content, `Forbidden transition-all in ${filePath}`).not.toMatch(
            /\btransition-all\b/,
          );
          expect(
            content,
            `Forbidden raw Tailwind backdrop-blur-* in ${filePath}; use .win-acrylic / .win-acrylic-dark`,
          ).not.toMatch(/\bbackdrop-blur-/);
        }
      }
    }
  });
});
