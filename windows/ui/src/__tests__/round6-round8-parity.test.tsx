import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import { ToastHost } from '../design-system';
import { Titlebar } from '../features/chrome/Titlebar';
import { AssetCard } from '../features/gallery/AssetCard';
import {
  DEFAULT_RING_GALLERY_PARAMS,
  RingCardTrack,
  adaptiveCardScale,
} from '../features/gallery/ringGalleryMath';
import { MoodboardGeneratorModal } from '../features/moodboard/MoodboardGeneratorModal';
import { SocialPostViewer } from '../features/quicklook/SocialPostViewer';
import { ExtensionsSettingsPane } from '../features/settings/SettingsPanesCaptureSystem';
import {
  DEFAULT_INSPECTOR_CARD_ORDER,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  useSyncAIStore,
} from '../stores';
import {
  createDefaultFilterCriteria,
  formatSocialDisplayHandle,
  resolveSocialMediaUrl,
  type AssetRecord,
  type FolderRecord,
} from '../types/domain';

function makeAsset(id: string, title: string, overrides: Partial<AssetRecord> = {}): AssetRecord {
  return {
    id,
    contentHash: `hash-${id}`,
    title,
    notes: '',
    mediaKind: 'image',
    mimeType: 'image/png',
    fileName: `${id}.png`,
    fileSizeBytes: 8192,
    pixelWidth: 1200,
    pixelHeight: 900,
    rating: 0,
    tags: [],
    suggestedTags: [],
    dominantColors: [
      { hex: '#D95D48', l: 55, a: 45, b: 30, proportion: 0.6 },
      { hex: '#3D5A80', l: 38, a: -4, b: -24, proportion: 0.4 },
    ],
    waveformPeaks: [],
    folderID: null,
    isTrashed: false,
    pinnedOffline: false,
    isLocalOriginalCached: true,
    createdAt: 760000000,
    updatedAt: 760000000,
    updatedHLC: 1,
    ...overrides,
  };
}

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
    cutAssetIds: [],
    criteria: createDefaultFilterCriteria(),
    semanticSearch: false,
    loading: false,
    bootstrapped: false,
    error: null,
  });
  useMoodboardStore.setState({
    boards: [],
    activeBoard: null,
    historyPast: [],
    historyFuture: [],
    selectedNodeIds: [],
    swappingNodeId: null,
    candidatePool: [],
    agentTrace: [],
    activeBoardAgentTrace: [],
    activeBoardLastSummary: null,
    loading: false,
    curating: false,
    isRefiningActiveBoard: false,
    openBoardFailedId: null,
    lastError: null,
  });
  useSyncAIStore.setState({
    syncConfig: null,
    syncStatus: null,
    cacheStats: null,
    syncing: false,
    migrating: false,
    aiState: null,
    typesafeState: null,
  });
}

describe('Round 6 & Round 8 — Titlebar Actions, Manual Moodboard Picker, 3D Ring, Xiaohongshu & Extensions Bridge', () => {
  beforeEach(() => {
    resetStores();
    setTransport(new InMemoryMockTransport());
  });

  // =========================================================================
  // 1. Round 8 — Titlebar Camera & Top-Shelf Interactivity
  // =========================================================================
  describe('Round 8 — Titlebar Camera & Top-Shelf Interactivity', () => {
    it('marks Camera and Top-Shelf buttons + cluster non-draggable, invokes commands cleanly, and surfaces rejected capture errors via toast', async () => {
      const transport = new InMemoryMockTransport();
      const captureSpy = vi.spyOn(transport, 'startRegionCapture');
      const shelfSpy = vi.spyOn(transport, 'toggleShelf').mockResolvedValue(true);
      setTransport(transport);

      render(
        <>
          <Titlebar />
          <ToastHost />
        </>,
      );

      const cameraBtn = screen.getByRole('button', { name: '区域截图采集' });
      const shelfBtn = screen.getByRole('button', { name: '切换顶部悬浮窗' });

      expect(cameraBtn.getAttribute('data-tauri-drag-region')).toBe('false');
      expect(shelfBtn.getAttribute('data-tauri-drag-region')).toBe('false');
      expect(cameraBtn.parentElement?.getAttribute('data-tauri-drag-region')).toBe('false');
      expect(shelfBtn.parentElement?.getAttribute('data-tauri-drag-region')).toBe('false');

      fireEvent.click(cameraBtn);
      await waitFor(() => {
        expect(captureSpy).toHaveBeenCalledTimes(1);
      });
      await waitFor(() => {
        expect(cameraBtn).not.toBeDisabled();
      });

      fireEvent.click(shelfBtn);
      await waitFor(() => {
        expect(shelfSpy).toHaveBeenCalledTimes(1);
      });
      await waitFor(() => {
        expect(shelfBtn).toHaveAttribute('aria-pressed', 'true');
        expect(shelfBtn).not.toBeDisabled();
      });

      // Rejected startRegionCapture shows an error toast instead of failing silently
      captureSpy.mockRejectedValueOnce(new Error('无法访问桌面屏幕捕获'));
      fireEvent.click(cameraBtn);

      expect(await screen.findByText('无法访问桌面屏幕捕获')).toBeInTheDocument();
      await waitFor(() => {
        expect(cameraBtn).not.toBeDisabled();
      });
    });
  });

  // =========================================================================
  // 2. Round 8 — Moodboard Generator Modal "手动挑选" Picker
  // =========================================================================
  describe('Round 8 — Moodboard Generator Modal Manual Picker', () => {
    it('renders explicit h-[92px] PickerAssetTiles with labels & swatches, supports search/folder/tag filtering, clear selection, and blocks 0-selected manual submission', async () => {
      const transport = new InMemoryMockTransport();
      const curateSpy = vi.spyOn(transport, 'curateMoodboard');
      setTransport(transport);

      const folderDesign: FolderRecord = {
        id: 'FOLDER-DESIGN',
        name: '视觉参考',
        parentID: null,
        sortOrder: 0,
        colorHex: null,
        customSymbol: null,
        assetCount: 2,
        createdAt: 760000000,
        updatedAt: 760000000,
      };
      const folderPhoto: FolderRecord = {
        id: 'FOLDER-PHOTO',
        name: '摄影光影',
        parentID: null,
        sortOrder: 1,
        colorHex: null,
        customSymbol: null,
        assetCount: 1,
        createdAt: 760000000,
        updatedAt: 760000000,
      };

      const asset1 = makeAsset('PICK-1', '极简石膏建筑', {
        folderID: folderDesign.id,
        tags: ['极简', '暖调'],
      });
      const asset2 = makeAsset('PICK-2', '晨雾海岸摄影', {
        folderID: folderPhoto.id,
        tags: ['自然'],
      });
      const assetSwatch = makeAsset('PICK-SWATCH', '赤陶主色', {
        mediaKind: 'document',
        fileName: 'terracotta.swatch',
        folderID: folderDesign.id,
        tags: ['暖调'],
        dominantColors: [{ hex: '#D95D48', l: 55, a: 45, b: 30, proportion: 1 }],
      });

      useLibraryStore.setState({
        assets: [asset1, asset2, assetSwatch],
        allAssets: [asset1, asset2, assetSwatch],
        folders: [folderDesign, folderPhoto],
        tagCounts: [
          { name: '暖调', count: 2 },
          { name: '自然', count: 1 },
        ],
      });

      const onClose = vi.fn();
      render(<MoodboardGeneratorModal open onClose={onClose} />);

      // Switch to "手动挑选" tab
      fireEvent.click(screen.getByRole('radio', { name: '手动挑选' }));

      const grid = await screen.findByTestId('moodboard-asset-picker-grid');
      const tiles = grid.querySelectorAll<HTMLButtonElement>('[data-picker-asset-id]');
      expect(tiles).toHaveLength(3);

      // Explicit height h-[92px] + visible labels & swatch hex
      tiles.forEach((tile) => {
        expect(tile.className).toContain('h-[92px]');
      });
      expect(screen.getByText('极简石膏建筑')).toBeInTheDocument();
      expect(screen.getByText('晨雾海岸摄影')).toBeInTheDocument();
      expect(screen.getByText('#D95D48')).toBeInTheDocument();

      // Clicking tiles updates selection counter
      expect(screen.getByText('已选 0 项 · 可选 3 项')).toBeInTheDocument();
      fireEvent.click(grid.querySelector<HTMLButtonElement>('[data-picker-asset-id="PICK-1"]')!);
      expect(screen.getByText('已选 1 项 · 可选 3 项')).toBeInTheDocument();
      fireEvent.click(
        grid.querySelector<HTMLButtonElement>('[data-picker-asset-id="PICK-SWATCH"]')!,
      );
      expect(screen.getByText('已选 2 项 · 可选 3 项')).toBeInTheDocument();

      // Inline search filtering
      const searchInput = screen.getByRole('textbox', { name: '筛选可选素材' });
      fireEvent.change(searchInput, { target: { value: '晨雾' } });
      expect(grid.querySelectorAll('[data-picker-asset-id]')).toHaveLength(1);
      expect(screen.getByText('已选 2 项 · 可选 1 项')).toBeInTheDocument();

      // Clear search and test Folder + Tag scope filters
      fireEvent.click(screen.getByRole('button', { name: '清空素材筛选词' }));
      expect(grid.querySelectorAll('[data-picker-asset-id]')).toHaveLength(3);

      fireEvent.click(screen.getByRole('button', { name: '视觉参考' }));
      expect(grid.querySelectorAll('[data-picker-asset-id]')).toHaveLength(2);

      fireEvent.click(screen.getByRole('button', { name: '#自然' }));
      // Folder 视觉参考 + tag #自然 yields 0 items -> empty state with "清除筛选条件"
      expect(screen.getByTestId('moodboard-picker-empty')).toBeInTheDocument();
      fireEvent.click(screen.getByRole('button', { name: '清除筛选条件' }));
      expect(
        screen.getByTestId('moodboard-asset-picker-grid').querySelectorAll('[data-picker-asset-id]'),
      ).toHaveLength(3);

      // "清空已选" clears selection back to 0
      fireEvent.click(screen.getByRole('button', { name: '清空已选' }));
      expect(screen.getByText('已选 0 项 · 可选 3 项')).toBeInTheDocument();

      // Submitting with 0 selected in manual mode is blocked cleanly
      fireEvent.click(screen.getByRole('button', { name: '立即生成情绪板' }));
      expect(screen.getByText('请至少勾选 1 项素材后再生成情绪板')).toBeInTheDocument();
      expect(curateSpy).not.toHaveBeenCalled();
      expect(onClose).not.toHaveBeenCalled();
    });
  });

  // =========================================================================
  // 3. Round 6 Track 1 — 3D Ring Gallery
  // =========================================================================
  describe('Round 6 Track 1 — 3D Ring Gallery Defaults, Aspect Widths & Bidirectional Scale', () => {
    it('matches final macOS v1.1.0 defaults, preserves landscape > portrait widths, and scales bidirectionally', () => {
      expect(DEFAULT_RING_GALLERY_PARAMS.perspective).toBe(1500);
      expect(DEFAULT_RING_GALLERY_PARAMS.depthBlur).toBe(2);
      expect(DEFAULT_RING_GALLERY_PARAMS.farFade).toBe(0.96);
      expect(DEFAULT_RING_GALLERY_PARAMS.cornerRadius).toBe(32);

      const landscape = makeAsset('RING-LANDSCAPE', 'Landscape 16:9', {
        pixelWidth: 1920,
        pixelHeight: 1080,
      });
      const portrait = makeAsset('RING-PORTRAIT', 'Portrait 5:8', {
        pixelWidth: 900,
        pixelHeight: 1440,
      });

      const track = RingCardTrack.build([landscape, portrait], DEFAULT_RING_GALLERY_PARAMS);
      expect(track.cardWidths[0]).toBeGreaterThan(track.cardWidths[1]);
      // Landscape 1920/1080 * 300 = 533px, Portrait 900/1440 * 300 = 188px (zero horizontal crop)
      expect(track.cardWidths[0]).toBe(Math.round(300 * (1920 / 1080)));
      expect(track.cardWidths[1]).toBe(Math.round(300 * (900 / 1440)));

      // Bidirectional viewport scaling: > 1.0 on wide viewports and < 1.0 on narrow viewports
      const wideScale = adaptiveCardScale(2560, 1440, 68, 72, DEFAULT_RING_GALLERY_PARAMS);
      const narrowScale = adaptiveCardScale(640, 480, 68, 72, DEFAULT_RING_GALLERY_PARAMS);
      expect(wideScale).toBeGreaterThan(1.0);
      expect(narrowScale).toBeLessThan(1.0);
    });
  });

  // =========================================================================
  // 4. Round 6 Track 2 — Xiaohongshu UI & Proxy Helpers
  // =========================================================================
  describe('Round 6 Track 2 — Xiaohongshu UI', () => {
    it('formatSocialDisplayHandle filters 24-hex userId, literal xiaohongshu, and duplicate authorName while formatting real handles', () => {
      expect(
        formatSocialDisplayHandle({
          platform: 'xiaohongshu',
          authorName: '建筑灵感手记',
          authorHandle: '61a2b3c4d5e6f708192a3b4c',
        }),
      ).toBeNull();
      expect(
        formatSocialDisplayHandle({
          platform: 'xiaohongshu',
          authorName: '建筑灵感手记',
          authorHandle: '@xiaohongshu',
        }),
      ).toBeNull();
      expect(
        formatSocialDisplayHandle({
          platform: 'xiaohongshu',
          authorName: '建筑灵感手记',
          authorHandle: '建筑灵感手记',
        }),
      ).toBeNull();
      expect(
        formatSocialDisplayHandle({
          platform: 'xiaohongshu',
          authorName: '建筑灵感手记',
          authorHandle: 'studio_notes',
        }),
      ).toBe('@studio_notes');
      expect(
        formatSocialDisplayHandle({
          platform: 'x',
          authorName: 'Design Feed',
          authorHandle: '@designfeed',
        }),
      ).toBe('@designfeed');
    });

    it('resolveSocialMediaUrl routes xhscdn/xiaohongshu URLs through proxy-xhs ONLY when isTauri=true', () => {
      const xhsUrl = 'https://sns-webpic-qc.xhscdn.com/20261124/note-cover.webp?imageView2/2/w/1080';
      const xUrl = 'https://pbs.twimg.com/media/sample.jpg';

      expect(resolveSocialMediaUrl(xhsUrl, true)).toBe(
        `http://charkle-media.localhost/proxy-xhs?url=${encodeURIComponent(xhsUrl)}`,
      );
      expect(resolveSocialMediaUrl(xhsUrl, false)).toBe(xhsUrl);
      expect(resolveSocialMediaUrl(xUrl, true)).toBe(xUrl);
      expect(resolveSocialMediaUrl(xUrl, false)).toBe(xUrl);
    });

    it('renders AssetCard for a 900x1440 Xiaohongshu asset with 小红书 badge and cover <img>', () => {
      const xhsAsset = makeAsset('XHS-CARD-1', '极简暖木住宅空间灵感', {
        mediaKind: 'webBookmark',
        pixelWidth: 900,
        pixelHeight: 1440,
        sourceURL: 'https://www.xiaohongshu.com/explore/65a1b2c3d4e5f60718293a4b',
        sourceDomain: 'xiaohongshu.com',
        richMetadata: {
          socialPost: {
            platform: 'xiaohongshu',
            authorName: '空间造物',
            authorHandle: '65a1b2c3d4e5f60718293a4b',
            articleTitle: '极简暖木住宅空间灵感',
            bodyText: '自然光与原木质感搭配。',
            originalURL: 'https://www.xiaohongshu.com/explore/65a1b2c3d4e5f60718293a4b',
            mediaURLs: ['https://sns-webpic-qc.xhscdn.com/cover.webp'],
            mediaThumbnailURLs: ['https://sns-webpic-qc.xhscdn.com/cover-thumb.webp'],
            attachments: [],
            hasVideo: false,
          },
        },
      });

      render(
        <AssetCard
          asset={xhsAsset}
          selected={false}
          orderedIds={[xhsAsset.id]}
          width={220}
          height={352}
        />,
      );

      expect(screen.getByText('小红书')).toBeInTheDocument();
      const coverImg = screen.getByRole('img', { name: '极简暖木住宅空间灵感' });
      expect(coverImg).toBeInTheDocument();
    });

    it('renders SocialPostViewer for a multi-image Xiaohongshu note with 小红书 badge, 在小红书中打开, 笔记 wording, and aspect-[3/4] grid preferring att.url', () => {
      const fullImg1 = 'https://sns-webpic-qc.xhscdn.com/full-1.webp';
      const fullImg2 = 'https://sns-webpic-qc.xhscdn.com/full-2.webp';
      const thumbImg1 = 'https://sns-webpic-qc.xhscdn.com/thumb-1.webp';
      const thumbImg2 = 'https://sns-webpic-qc.xhscdn.com/thumb-2.webp';

      const xhsNote = makeAsset('XHS-NOTE-1', '东京展馆材质配色笔记', {
        mediaKind: 'webBookmark',
        pixelWidth: 900,
        pixelHeight: 1440,
        sourceURL: 'https://www.xiaohongshu.com/explore/66b2c3d4e5f60718293a4c5d',
        sourceDomain: 'xiaohongshu.com',
        richMetadata: {
          socialPost: {
            platform: 'xiaohongshu',
            authorName: '展陈观察室',
            authorHandle: '66b2c3d4e5f60718293a4c5d',
            articleTitle: '东京展馆材质配色笔记',
            bodyText: '清水混凝土与温润黄铜的光影对照。',
            originalURL: 'https://www.xiaohongshu.com/explore/66b2c3d4e5f60718293a4c5d',
            mediaURLs: [fullImg1, fullImg2],
            mediaThumbnailURLs: [thumbImg1, thumbImg2],
            attachments: [
              { id: 'att-1', kind: 'photo', url: fullImg1, thumbnailURL: thumbImg1 },
              { id: 'att-2', kind: 'photo', url: fullImg2, thumbnailURL: thumbImg2 },
            ],
            hasVideo: false,
          },
        },
      });

      const { container } = render(<SocialPostViewer asset={xhsNote} />);

      expect(screen.getByText('小红书')).toBeInTheDocument();
      expect(screen.getByRole('button', { name: '在小红书中打开' })).toBeInTheDocument();
      expect(screen.getByText('笔记内含 2 个媒体')).toBeInTheDocument();
      expect(container.textContent).not.toContain('推文');

      // 24-hex userId handle must be hidden
      expect(container.textContent).not.toContain('66b2c3d4e5f60718293a4c5d');

      // Multi-image grid uses aspect-[3/4] and prefers att.url over att.thumbnailURL
      const gridCells = container.querySelectorAll<HTMLElement>('.aspect-\\[3\\/4\\]');
      expect(gridCells).toHaveLength(2);
      const imgs = Array.from(gridCells).map((cell) => cell.querySelector('img'));
      expect(imgs[0]?.getAttribute('src')).toBe(fullImg1);
      expect(imgs[1]?.getAttribute('src')).toBe(fullImg2);
    });
  });

  // =========================================================================
  // 5. Round 6 Track 3 — Settings Tab 8 ExtensionsSettingsPane
  // =========================================================================
  describe('Round 6 Track 3 — Settings Tab 8 ExtensionsSettingsPane', () => {
    it('displays browser extension bridge status, toggles enabled/auto-pair, reveals bundled extension, and expands advanced token panel', async () => {
      const transport = new InMemoryMockTransport();
      const revealSpy = vi.spyOn(transport, 'revealBundledBrowserExtension');
      const regenSpy = vi.spyOn(transport, 'regenerateExtensionBridgeToken');
      setTransport(transport);

      render(
        <>
          <ExtensionsSettingsPane />
          <ToastHost />
        </>,
      );

      expect(
        screen.getByText('浏览器扩展（Chrome / Edge / Arc / Brave）'),
      ).toBeInTheDocument();

      // Bridge loads in running ("已就绪") state
      expect(await screen.findByText('已就绪')).toBeInTheDocument();

      const bridgeSwitch = screen.getByRole('switch', { name: '启用桌面端本地连接桥接' });
      const autoPairSwitch = screen.getByRole('switch', { name: '允许同机扩展自动免密配对' });
      expect(bridgeSwitch).toHaveAttribute('aria-checked', 'true');
      expect(autoPairSwitch).not.toBeDisabled();

      // Toggling bridge off updates badge to 已暂停 and disables auto-pair switch
      fireEvent.click(bridgeSwitch);
      expect(await screen.findByText('已暂停')).toBeInTheDocument();
      await waitFor(() => {
        expect(bridgeSwitch).toHaveAttribute('aria-checked', 'false');
        expect(autoPairSwitch).toBeDisabled();
      });

      // Clicking "在资源管理器中定位扩展" invokes revealBundledBrowserExtension
      const revealBtn = screen.getByTestId('reveal-browser-extension-btn');
      fireEvent.click(revealBtn);
      await waitFor(() => {
        expect(revealSpy).toHaveBeenCalledTimes(1);
      });

      // "高级：手动连接地址与访问令牌" is collapsed by default
      expect(screen.queryByTestId('extension-bridge-token-value')).not.toBeInTheDocument();

      // Expanding reveals masked token + 重新生成令牌 button
      fireEvent.click(screen.getByRole('button', { name: /高级：手动连接地址与访问令牌/ }));
      const tokenEl = await screen.findByTestId('extension-bridge-token-value');
      const maskedInitial = tokenEl.textContent ?? '';
      expect(maskedInitial).toContain('•');

      const regenBtn = screen.getByTestId('regenerate-extension-token-btn');
      fireEvent.click(regenBtn);
      await waitFor(() => {
        expect(regenSpy).toHaveBeenCalledTimes(1);
      });
    });
  });
});
